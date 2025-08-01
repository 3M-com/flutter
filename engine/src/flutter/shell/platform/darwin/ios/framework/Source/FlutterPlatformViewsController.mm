// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "shell/platform/darwin/ios/framework/Source/FlutterPlatformViewsController.h"

#include "flutter/display_list/effects/image_filters/dl_blur_image_filter.h"
#include "flutter/display_list/utils/dl_matrix_clip_tracker.h"
#include "flutter/flow/surface_frame.h"
#include "flutter/flow/view_slicer.h"
#include "flutter/fml/make_copyable.h"
#include "flutter/fml/synchronization/count_down_latch.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterOverlayView.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterView.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/overlay_layer_pool.h"
#import "flutter/shell/platform/darwin/ios/ios_surface.h"

using flutter::DlISize;
using flutter::DlMatrix;
using flutter::DlRect;
using flutter::DlRoundRect;

static constexpr NSUInteger kFlutterClippingMaskViewPoolCapacity = 5;

struct LayerData {
  DlRect rect;
  int64_t view_id;
  int64_t overlay_id;
  std::shared_ptr<flutter::OverlayLayer> layer;
};
using LayersMap = std::unordered_map<int64_t, LayerData>;

/// Each of the following structs stores part of the platform view hierarchy according to its
/// ID.
///
/// This data must only be accessed on the platform thread.
struct PlatformViewData {
  NSObject<FlutterPlatformView>* view;
  FlutterTouchInterceptingView* touch_interceptor;
  UIView* root_view;
};

// Converts a DlMatrix to CATransform3D.
static CATransform3D GetCATransform3DFromDlMatrix(const DlMatrix& matrix) {
  CATransform3D transform = CATransform3DIdentity;
  transform.m11 = matrix.m[0];
  transform.m12 = matrix.m[1];
  transform.m13 = matrix.m[2];
  transform.m14 = matrix.m[3];

  transform.m21 = matrix.m[4];
  transform.m22 = matrix.m[5];
  transform.m23 = matrix.m[6];
  transform.m24 = matrix.m[7];

  transform.m31 = matrix.m[8];
  transform.m32 = matrix.m[9];
  transform.m33 = matrix.m[10];
  transform.m34 = matrix.m[11];

  transform.m41 = matrix.m[12];
  transform.m42 = matrix.m[13];
  transform.m43 = matrix.m[14];
  transform.m44 = matrix.m[15];
  return transform;
}

// Reset the anchor of `layer` to match the transform operation from flow.
//
// The position of the `layer` should be unchanged after resetting the anchor.
static void ResetAnchor(CALayer* layer) {
  // Flow uses (0, 0) to apply transform matrix so we need to match that in Quartz.
  layer.anchorPoint = CGPointZero;
  layer.position = CGPointZero;
}

static CGRect GetCGRectFromDlRect(const DlRect& clipDlRect) {
  return CGRectMake(clipDlRect.GetLeft(),   //
                    clipDlRect.GetTop(),    //
                    clipDlRect.GetWidth(),  //
                    clipDlRect.GetHeight());
}

@interface FlutterPlatformViewsController ()

// The pool of reusable view layers. The pool allows to recycle layer in each frame.
@property(nonatomic, readonly) flutter::OverlayLayerPool* layerPool;

// The platform view's |EmbedderViewSlice| keyed off the view id, which contains any subsequent
// operation until the next platform view or the end of the last leaf node in the layer tree.
//
// The Slices are deleted by the PlatformViewsController.reset().
@property(nonatomic, readonly)
    std::unordered_map<int64_t, std::unique_ptr<flutter::EmbedderViewSlice>>& slices;

@property(nonatomic, readonly) FlutterClippingMaskViewPool* maskViewPool;

@property(nonatomic, readonly)
    std::unordered_map<std::string, NSObject<FlutterPlatformViewFactory>*>& factories;

// The FlutterPlatformViewGestureRecognizersBlockingPolicy for each type of platform view.
@property(nonatomic, readonly)
    std::unordered_map<std::string, FlutterPlatformViewGestureRecognizersBlockingPolicy>&
        gestureRecognizersBlockingPolicies;

/// The size of the current onscreen surface in physical pixels.
@property(nonatomic, assign) DlISize frameSize;

/// The task runner for posting tasks to the platform thread.
@property(nonatomic, readonly) const fml::RefPtr<fml::TaskRunner>& platformTaskRunner;

/// This data must only be accessed on the platform thread.
@property(nonatomic, readonly) std::unordered_map<int64_t, PlatformViewData>& platformViews;

/// The composition parameters for each platform view.
///
/// This state is only modified on the raster thread.
@property(nonatomic, readonly)
    std::unordered_map<int64_t, flutter::EmbeddedViewParams>& currentCompositionParams;

/// Method channel `OnDispose` calls adds the views to be disposed to this set to be disposed on
/// the next frame.
///
/// This state is modified on both the platform and raster thread.
@property(nonatomic, readonly) std::unordered_set<int64_t>& viewsToDispose;

/// view IDs in composition order.
///
/// This state is only modified on the raster thread.
@property(nonatomic, readonly) std::vector<int64_t>& compositionOrder;

/// platform view IDs visited during layer tree composition.
///
/// This state is only modified on the raster thread.
@property(nonatomic, readonly) std::vector<int64_t>& visitedPlatformViews;

/// Only composite platform views in this set.
///
/// This state is only modified on the raster thread.
@property(nonatomic, readonly) std::unordered_set<int64_t>& viewsToRecomposite;

/// @brief The composition order from the previous thread.
///
/// Only accessed from the platform thread.
@property(nonatomic, readonly) std::vector<int64_t>& previousCompositionOrder;

/// Whether the previous frame had any platform views in active composition order.
///
/// This state is tracked so that the first frame after removing the last platform view
/// runs through the platform view rendering code path, giving us a chance to remove the
/// platform view from the UIView hierarchy.
///
/// Only accessed from the raster thread.
@property(nonatomic, assign) BOOL hadPlatformViews;

/// Whether blurred backdrop filters can be applied.
///
/// Defaults to YES, but becomes NO if blurred backdrop filters cannot be applied.
@property(nonatomic, assign) BOOL canApplyBlurBackdrop;

/// Populate any missing overlay layers.
///
/// This requires posting a task to the platform thread and blocking on its completion.
- (void)createMissingOverlays:(size_t)requiredOverlayLayers
               withIosContext:(const std::shared_ptr<flutter::IOSContext>&)iosContext;

/// Update the buffers and mutate the platform views in CATransaction on the platform thread.
- (void)performSubmit:(const LayersMap&)platformViewLayers
    currentCompositionParams:
        (std::unordered_map<int64_t, flutter::EmbeddedViewParams>&)currentCompositionParams
          viewsToRecomposite:(const std::unordered_set<int64_t>&)viewsToRecomposite
            compositionOrder:(const std::vector<int64_t>&)compositionOrder
                unusedLayers:
                    (const std::vector<std::shared_ptr<flutter::OverlayLayer>>&)unusedLayers
               surfaceFrames:
                   (const std::vector<std::unique_ptr<flutter::SurfaceFrame>>&)surfaceFrames;

- (void)onCreate:(FlutterMethodCall*)call result:(FlutterResult)result;
- (void)onDispose:(FlutterMethodCall*)call result:(FlutterResult)result;
- (void)onAcceptGesture:(FlutterMethodCall*)call result:(FlutterResult)result;
- (void)onRejectGesture:(FlutterMethodCall*)call result:(FlutterResult)result;

- (void)clipViewSetMaskView:(UIView*)clipView;

// Applies the mutators in the mutatorsStack to the UIView chain that was constructed by
// `ReconstructClipViewsChain`
//
// Clips are applied to the `embeddedView`'s super view(|ChildClippingView|) using a
// |FlutterClippingMaskView|. Transforms are applied to `embeddedView`
//
// The `boundingRect` is the final bounding rect of the PlatformView
// (EmbeddedViewParams::finalBoundingRect). If a clip mutator's rect contains the final bounding
// rect of the PlatformView, the clip mutator is not applied for performance optimization.
//
// This method is only called when the `embeddedView` needs to be re-composited at the current
// frame. See: `compositeView:withParams:` for details.
- (void)applyMutators:(const flutter::MutatorsStack&)mutatorsStack
         embeddedView:(UIView*)embeddedView
         boundingRect:(const DlRect&)boundingRect;

// Appends the overlay views and platform view and sets their z index based on the composition
// order.
- (void)bringLayersIntoView:(const LayersMap&)layerMap
       withCompositionOrder:(const std::vector<int64_t>&)compositionOrder;

- (std::shared_ptr<flutter::OverlayLayer>)nextLayerInPool;

/// Runs on the platform thread.
- (void)createLayerWithIosContext:(const std::shared_ptr<flutter::IOSContext>&)iosContext
                      pixelFormat:(MTLPixelFormat)pixelFormat;

/// Removes overlay views and platform views that aren't needed in the current frame.
/// Must run on the platform thread.
- (void)removeUnusedLayers:(const std::vector<std::shared_ptr<flutter::OverlayLayer>>&)unusedLayers
      withCompositionOrder:(const std::vector<int64_t>&)compositionOrder;

/// Computes and returns all views to be disposed on the platform thread, removes them from
/// self.platformViews, self.viewsToRecomposite, and self.currentCompositionParams. Any views that
/// still require compositing are not returned, but instead added to `viewsToDelayDispose` for
/// disposal on the next call.
- (std::vector<UIView*>)computeViewsToDispose;

/// Resets the state of the frame.
- (void)resetFrameState;
@end

@implementation FlutterPlatformViewsController {
  // TODO(cbracken): Replace with Obj-C types and use @property declarations to automatically
  // synthesize the ivars.
  //
  // These ivars are required because we're transitioning the previous C++ implementation to Obj-C.
  // We require ivars to declare the concrete types and then wrap with @property declarations that
  // return a reference to the ivar, allowing for use like `self.layerPool` and
  // `self.slices[viewId] = x`.
  std::unique_ptr<flutter::OverlayLayerPool> _layerPool;
  std::unordered_map<int64_t, std::unique_ptr<flutter::EmbedderViewSlice>> _slices;
  std::unordered_map<std::string, NSObject<FlutterPlatformViewFactory>*> _factories;
  std::unordered_map<std::string, FlutterPlatformViewGestureRecognizersBlockingPolicy>
      _gestureRecognizersBlockingPolicies;
  fml::RefPtr<fml::TaskRunner> _platformTaskRunner;
  std::unordered_map<int64_t, PlatformViewData> _platformViews;
  std::unordered_map<int64_t, flutter::EmbeddedViewParams> _currentCompositionParams;
  std::unordered_set<int64_t> _viewsToDispose;
  std::vector<int64_t> _compositionOrder;
  std::vector<int64_t> _visitedPlatformViews;
  std::unordered_set<int64_t> _viewsToRecomposite;
  std::vector<int64_t> _previousCompositionOrder;
}

- (id)init {
  if (self = [super init]) {
    _layerPool = std::make_unique<flutter::OverlayLayerPool>();
    _maskViewPool =
        [[FlutterClippingMaskViewPool alloc] initWithCapacity:kFlutterClippingMaskViewPoolCapacity];
    _hadPlatformViews = NO;
    _canApplyBlurBackdrop = YES;
  }
  return self;
}

- (const fml::RefPtr<fml::TaskRunner>&)taskRunner {
  return _platformTaskRunner;
}

- (void)setTaskRunner:(const fml::RefPtr<fml::TaskRunner>&)platformTaskRunner {
  _platformTaskRunner = platformTaskRunner;
}

- (void)onMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([[call method] isEqualToString:@"create"]) {
    [self onCreate:call result:result];
  } else if ([[call method] isEqualToString:@"dispose"]) {
    [self onDispose:call result:result];
  } else if ([[call method] isEqualToString:@"acceptGesture"]) {
    [self onAcceptGesture:call result:result];
  } else if ([[call method] isEqualToString:@"rejectGesture"]) {
    [self onRejectGesture:call result:result];
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)onCreate:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSDictionary<NSString*, id>* args = [call arguments];

  int64_t viewId = [args[@"id"] longLongValue];
  NSString* viewTypeString = args[@"viewType"];
  std::string viewType(viewTypeString.UTF8String);

  if (self.platformViews.count(viewId) != 0) {
    result([FlutterError errorWithCode:@"recreating_view"
                               message:@"trying to create an already created view"
                               details:[NSString stringWithFormat:@"view id: '%lld'", viewId]]);
    return;
  }

  NSObject<FlutterPlatformViewFactory>* factory = self.factories[viewType];
  if (factory == nil) {
    result([FlutterError
        errorWithCode:@"unregistered_view_type"
              message:[NSString stringWithFormat:@"A UIKitView widget is trying to create a "
                                                 @"PlatformView with an unregistered type: < %@ >",
                                                 viewTypeString]
              details:@"If you are the author of the PlatformView, make sure `registerViewFactory` "
                      @"is invoked.\n"
                      @"See: "
                      @"https://docs.flutter.dev/development/platform-integration/"
                      @"platform-views#on-the-platform-side-1 for more details.\n"
                      @"If you are not the author of the PlatformView, make sure to call "
                      @"`GeneratedPluginRegistrant.register`."]);
    return;
  }

  id params = nil;
  if ([factory respondsToSelector:@selector(createArgsCodec)]) {
    NSObject<FlutterMessageCodec>* codec = [factory createArgsCodec];
    if (codec != nil && args[@"params"] != nil) {
      FlutterStandardTypedData* paramsData = args[@"params"];
      params = [codec decode:paramsData.data];
    }
  }

  NSObject<FlutterPlatformView>* embeddedView = [factory createWithFrame:CGRectZero
                                                          viewIdentifier:viewId
                                                               arguments:params];
  UIView* platformView = [embeddedView view];
  // Set a unique view identifier, so the platform view can be identified in unit tests.
  platformView.accessibilityIdentifier = [NSString stringWithFormat:@"platform_view[%lld]", viewId];

  FlutterTouchInterceptingView* touchInterceptor = [[FlutterTouchInterceptingView alloc]
                  initWithEmbeddedView:platformView
               platformViewsController:self
      gestureRecognizersBlockingPolicy:self.gestureRecognizersBlockingPolicies[viewType]];

  ChildClippingView* clippingView = [[ChildClippingView alloc] initWithFrame:CGRectZero];
  [clippingView addSubview:touchInterceptor];

  self.platformViews.emplace(viewId, PlatformViewData{
                                         .view = embeddedView,                   //
                                         .touch_interceptor = touchInterceptor,  //
                                         .root_view = clippingView               //
                                     });

  result(nil);
}

- (void)onDispose:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSNumber* arg = [call arguments];
  int64_t viewId = [arg longLongValue];

  if (self.platformViews.count(viewId) == 0) {
    result([FlutterError errorWithCode:@"unknown_view"
                               message:@"trying to dispose an unknown"
                               details:[NSString stringWithFormat:@"view id: '%lld'", viewId]]);
    return;
  }
  // We wait for next submitFrame to dispose views.
  self.viewsToDispose.insert(viewId);
  result(nil);
}

- (void)onAcceptGesture:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSDictionary<NSString*, id>* args = [call arguments];
  int64_t viewId = [args[@"id"] longLongValue];

  if (self.platformViews.count(viewId) == 0) {
    result([FlutterError errorWithCode:@"unknown_view"
                               message:@"trying to set gesture state for an unknown view"
                               details:[NSString stringWithFormat:@"view id: '%lld'", viewId]]);
    return;
  }

  FlutterTouchInterceptingView* view = self.platformViews[viewId].touch_interceptor;
  [view releaseGesture];

  result(nil);
}

- (void)onRejectGesture:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSDictionary<NSString*, id>* args = [call arguments];
  int64_t viewId = [args[@"id"] longLongValue];

  if (self.platformViews.count(viewId) == 0) {
    result([FlutterError errorWithCode:@"unknown_view"
                               message:@"trying to set gesture state for an unknown view"
                               details:[NSString stringWithFormat:@"view id: '%lld'", viewId]]);
    return;
  }

  FlutterTouchInterceptingView* view = self.platformViews[viewId].touch_interceptor;
  [view blockGesture];

  result(nil);
}

- (void)registerViewFactory:(NSObject<FlutterPlatformViewFactory>*)factory
                              withId:(NSString*)factoryId
    gestureRecognizersBlockingPolicy:
        (FlutterPlatformViewGestureRecognizersBlockingPolicy)gestureRecognizerBlockingPolicy {
  std::string idString([factoryId UTF8String]);
  FML_CHECK(self.factories.count(idString) == 0);
  self.factories[idString] = factory;
  self.gestureRecognizersBlockingPolicies[idString] = gestureRecognizerBlockingPolicy;
}

- (void)beginFrameWithSize:(DlISize)frameSize {
  [self resetFrameState];
  self.frameSize = frameSize;
}

- (void)cancelFrame {
  [self resetFrameState];
}

- (flutter::PostPrerollResult)postPrerollActionWithThreadMerger:
    (const fml::RefPtr<fml::RasterThreadMerger>&)rasterThreadMerger {
  return flutter::PostPrerollResult::kSuccess;
}

- (void)endFrameWithResubmit:(BOOL)shouldResubmitFrame
                threadMerger:(const fml::RefPtr<fml::RasterThreadMerger>&)rasterThreadMerger {
}

- (void)pushFilterToVisitedPlatformViews:(const std::shared_ptr<flutter::DlImageFilter>&)filter
                                withRect:(const flutter::DlRect&)filterRect {
  for (int64_t id : self.visitedPlatformViews) {
    flutter::EmbeddedViewParams params = self.currentCompositionParams[id];
    params.PushImageFilter(filter, filterRect);
    self.currentCompositionParams[id] = params;
  }
}

- (void)prerollCompositeEmbeddedView:(int64_t)viewId
                          withParams:(std::unique_ptr<flutter::EmbeddedViewParams>)params {
  DlRect viewBounds = DlRect::MakeSize(self.frameSize);
  std::unique_ptr<flutter::EmbedderViewSlice> view;
  view = std::make_unique<flutter::DisplayListEmbedderViewSlice>(viewBounds);
  self.slices.insert_or_assign(viewId, std::move(view));

  self.compositionOrder.push_back(viewId);

  if (self.currentCompositionParams.count(viewId) == 1 &&
      self.currentCompositionParams[viewId] == *params.get()) {
    // Do nothing if the params didn't change.
    return;
  }
  self.currentCompositionParams[viewId] = flutter::EmbeddedViewParams(*params.get());
  self.viewsToRecomposite.insert(viewId);
}

- (size_t)embeddedViewCount {
  return self.compositionOrder.size();
}

- (UIView*)platformViewForId:(int64_t)viewId {
  return [self flutterTouchInterceptingViewForId:viewId].embeddedView;
}

- (FlutterTouchInterceptingView*)flutterTouchInterceptingViewForId:(int64_t)viewId {
  if (self.platformViews.empty()) {
    return nil;
  }
  return self.platformViews[viewId].touch_interceptor;
}

- (long)firstResponderPlatformViewId {
  for (auto const& [id, platformViewData] : self.platformViews) {
    UIView* rootView = platformViewData.root_view;
    if (rootView.flt_hasFirstResponderInViewHierarchySubtree) {
      return id;
    }
  }
  return -1;
}

- (void)clipViewSetMaskView:(UIView*)clipView {
  FML_DCHECK([[NSThread currentThread] isMainThread]);
  if (clipView.maskView) {
    return;
  }
  CGRect frame =
      CGRectMake(-clipView.frame.origin.x, -clipView.frame.origin.y,
                 CGRectGetWidth(self.flutterView.bounds), CGRectGetHeight(self.flutterView.bounds));
  clipView.maskView = [self.maskViewPool getMaskViewWithFrame:frame];
}

- (void)applyMutators:(const flutter::MutatorsStack&)mutatorsStack
         embeddedView:(UIView*)embeddedView
         boundingRect:(const DlRect&)boundingRect {
  if (self.flutterView == nil) {
    return;
  }

  ResetAnchor(embeddedView.layer);
  ChildClippingView* clipView = (ChildClippingView*)embeddedView.superview;

  DlMatrix transformMatrix;
  NSMutableArray* blurFilters = [[NSMutableArray alloc] init];
  FML_DCHECK(!clipView.maskView ||
             [clipView.maskView isKindOfClass:[FlutterClippingMaskView class]]);
  if (clipView.maskView) {
    [self.maskViewPool insertViewToPoolIfNeeded:(FlutterClippingMaskView*)(clipView.maskView)];
    clipView.maskView = nil;
  }
  CGFloat screenScale = [UIScreen mainScreen].scale;
  auto iter = mutatorsStack.Begin();
  while (iter != mutatorsStack.End()) {
    switch ((*iter)->GetType()) {
      case flutter::MutatorType::kTransform: {
        transformMatrix = transformMatrix * (*iter)->GetMatrix();
        break;
      }
      case flutter::MutatorType::kClipRect: {
        if (flutter::DisplayListMatrixClipState::TransformedRectCoversBounds(
                (*iter)->GetRect(), transformMatrix, boundingRect)) {
          break;
        }
        [self clipViewSetMaskView:clipView];
        [(FlutterClippingMaskView*)clipView.maskView clipRect:(*iter)->GetRect()
                                                       matrix:transformMatrix];
        break;
      }
      case flutter::MutatorType::kClipRRect: {
        if (flutter::DisplayListMatrixClipState::TransformedRRectCoversBounds(
                (*iter)->GetRRect(), transformMatrix, boundingRect)) {
          break;
        }
        [self clipViewSetMaskView:clipView];
        [(FlutterClippingMaskView*)clipView.maskView clipRRect:(*iter)->GetRRect()
                                                        matrix:transformMatrix];
        break;
      }
      case flutter::MutatorType::kClipRSE: {
        if (flutter::DisplayListMatrixClipState::TransformedRoundSuperellipseCoversBounds(
                (*iter)->GetRSE(), transformMatrix, boundingRect)) {
          break;
        }
        [self clipViewSetMaskView:clipView];
        [(FlutterClippingMaskView*)clipView.maskView clipRRect:(*iter)->GetRSEApproximation()
                                                        matrix:transformMatrix];
        break;
      }
      case flutter::MutatorType::kClipPath: {
        // TODO(cyanglaz): Find a way to pre-determine if path contains the PlatformView boudning
        // rect. See `ClipRRectContainsPlatformViewBoundingRect`.
        // https://github.com/flutter/flutter/issues/118650
        [self clipViewSetMaskView:clipView];
        [(FlutterClippingMaskView*)clipView.maskView clipPath:(*iter)->GetPath()
                                                       matrix:transformMatrix];
        break;
      }
      case flutter::MutatorType::kOpacity:
        embeddedView.alpha = (*iter)->GetAlphaFloat() * embeddedView.alpha;
        break;
      case flutter::MutatorType::kBackdropFilter: {
        // Only support DlBlurImageFilter for BackdropFilter.
        if (!self.canApplyBlurBackdrop || !(*iter)->GetFilterMutation().GetFilter().asBlur()) {
          break;
        }
        CGRect filterRect = GetCGRectFromDlRect((*iter)->GetFilterMutation().GetFilterRect());
        // `filterRect` is in global coordinates. We need to convert to local space.
        filterRect = CGRectApplyAffineTransform(
            filterRect, CGAffineTransformMakeScale(1 / screenScale, 1 / screenScale));
        // `filterRect` reprents the rect that should be filtered inside the `_flutterView`.
        // The `PlatformViewFilter` needs the frame inside the `clipView` that needs to be
        // filtered.
        if (CGRectIsNull(CGRectIntersection(filterRect, clipView.frame))) {
          break;
        }
        CGRect intersection = CGRectIntersection(filterRect, clipView.frame);
        CGRect frameInClipView = [self.flutterView convertRect:intersection toView:clipView];
        // sigma_x is arbitrarily chosen as the radius value because Quartz sets
        // sigma_x and sigma_y equal to each other. DlBlurImageFilter's Tile Mode
        // is not supported in Quartz's gaussianBlur CAFilter, so it is not used
        // to blur the PlatformView.
        CGFloat blurRadius = (*iter)->GetFilterMutation().GetFilter().asBlur()->sigma_x();
        UIVisualEffectView* visualEffectView = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleLight]];
        PlatformViewFilter* filter = [[PlatformViewFilter alloc] initWithFrame:frameInClipView
                                                                    blurRadius:blurRadius
                                                              visualEffectView:visualEffectView];
        if (!filter) {
          self.canApplyBlurBackdrop = NO;
        } else {
          [blurFilters addObject:filter];
        }
        break;
      }
    }
    ++iter;
  }

  if (self.canApplyBlurBackdrop) {
    [clipView applyBlurBackdropFilters:blurFilters];
  }

  // The UIKit frame is set based on the logical resolution (points) instead of physical.
  // (https://developer.apple.com/library/archive/documentation/DeviceInformation/Reference/iOSDeviceCompatibility/Displays/Displays.html).
  // However, flow is based on the physical resolution. For example, 1000 pixels in flow equals
  // 500 points in UIKit for devices that has screenScale of 2. We need to scale the transformMatrix
  // down to the logical resoltion before applying it to the layer of PlatformView.
  flutter::DlScalar pointScale = 1.0 / screenScale;
  transformMatrix = DlMatrix::MakeScale({pointScale, pointScale, 1}) * transformMatrix;

  // Reverse the offset of the clipView.
  // The clipView's frame includes the final translate of the final transform matrix.
  // Thus, this translate needs to be reversed so the platform view can layout at the correct
  // offset.
  //
  // Note that the transforms are not applied to the clipping paths because clipping paths happen on
  // the mask view, whose origin is always (0,0) to the _flutterView.
  impeller::Vector3 origin = impeller::Vector3(clipView.frame.origin.x, clipView.frame.origin.y);
  transformMatrix = DlMatrix::MakeTranslation(-origin) * transformMatrix;

  embeddedView.layer.transform = GetCATransform3DFromDlMatrix(transformMatrix);
}

- (void)compositeView:(int64_t)viewId withParams:(const flutter::EmbeddedViewParams&)params {
  // TODO(https://github.com/flutter/flutter/issues/109700)
  CGRect frame = CGRectMake(0, 0, params.sizePoints().width, params.sizePoints().height);
  FlutterTouchInterceptingView* touchInterceptor = self.platformViews[viewId].touch_interceptor;
  touchInterceptor.layer.transform = CATransform3DIdentity;
  touchInterceptor.frame = frame;
  touchInterceptor.alpha = 1;

  const flutter::MutatorsStack& mutatorStack = params.mutatorsStack();
  UIView* clippingView = self.platformViews[viewId].root_view;
  // The frame of the clipping view should be the final bounding rect.
  // Because the translate matrix in the Mutator Stack also includes the offset,
  // when we apply the transforms matrix in |applyMutators:embeddedView:boundingRect|, we need
  // to remember to do a reverse translate.
  const DlRect& rect = params.finalBoundingRect();
  CGFloat screenScale = [UIScreen mainScreen].scale;
  clippingView.frame = CGRectMake(rect.GetX() / screenScale, rect.GetY() / screenScale,
                                  rect.GetWidth() / screenScale, rect.GetHeight() / screenScale);
  [self applyMutators:mutatorStack embeddedView:touchInterceptor boundingRect:rect];
}

- (flutter::DlCanvas*)compositeEmbeddedViewWithId:(int64_t)viewId {
  FML_DCHECK(self.slices.find(viewId) != self.slices.end());
  return self.slices[viewId]->canvas();
}

- (void)reset {
  // Reset will only be called from the raster thread or a merged raster/platform thread.
  // _platformViews must only be modified on the platform thread, and any operations that
  // read or modify platform views should occur there.
  fml::TaskRunner::RunNowOrPostTask(self.platformTaskRunner, [self]() {
    for (int64_t viewId : self.compositionOrder) {
      [self.platformViews[viewId].root_view removeFromSuperview];
    }
    self.platformViews.clear();
    self.previousCompositionOrder.clear();
  });

  self.compositionOrder.clear();
  self.slices.clear();
  self.currentCompositionParams.clear();
  self.viewsToRecomposite.clear();
  self.layerPool->RecycleLayers();
  self.visitedPlatformViews.clear();
}

- (BOOL)submitFrame:(std::unique_ptr<flutter::SurfaceFrame>)background_frame
     withIosContext:(const std::shared_ptr<flutter::IOSContext>&)iosContext {
  TRACE_EVENT0("flutter", "PlatformViewsController::SubmitFrame");

  // No platform views to render; we're done.
  if (self.flutterView == nil || (self.compositionOrder.empty() && !self.hadPlatformViews)) {
    self.hadPlatformViews = NO;
    return background_frame->Submit();
  }
  self.hadPlatformViews = !self.compositionOrder.empty();

  bool didEncode = true;
  LayersMap platformViewLayers;
  std::vector<std::unique_ptr<flutter::SurfaceFrame>> surfaceFrames;
  surfaceFrames.reserve(self.compositionOrder.size());
  std::unordered_map<int64_t, DlRect> viewRects;

  for (int64_t viewId : self.compositionOrder) {
    viewRects[viewId] = self.currentCompositionParams[viewId].finalBoundingRect();
  }

  std::unordered_map<int64_t, DlRect> overlayLayers =
      SliceViews(background_frame->Canvas(), self.compositionOrder, self.slices, viewRects);

  size_t requiredOverlayLayers = 0;
  for (int64_t viewId : self.compositionOrder) {
    std::unordered_map<int64_t, DlRect>::const_iterator overlay = overlayLayers.find(viewId);
    if (overlay == overlayLayers.end()) {
      continue;
    }
    requiredOverlayLayers++;
  }

  // If there are not sufficient overlay layers, we must construct them on the platform
  // thread, at least until we've refactored iOS surface creation to use IOSurfaces
  // instead of CALayers.
  [self createMissingOverlays:requiredOverlayLayers withIosContext:iosContext];

  int64_t overlayId = 0;
  for (int64_t viewId : self.compositionOrder) {
    std::unordered_map<int64_t, DlRect>::const_iterator overlay = overlayLayers.find(viewId);
    if (overlay == overlayLayers.end()) {
      continue;
    }
    std::shared_ptr<flutter::OverlayLayer> layer = self.nextLayerInPool;
    if (!layer) {
      continue;
    }

    std::unique_ptr<flutter::SurfaceFrame> frame =
        layer->surface->AcquireFrame(flutter::ToSkISize(self.frameSize));
    // If frame is null, AcquireFrame already printed out an error message.
    if (!frame) {
      continue;
    }
    flutter::DlCanvas* overlayCanvas = frame->Canvas();
    int restoreCount = overlayCanvas->GetSaveCount();
    overlayCanvas->Save();
    overlayCanvas->ClipRect(overlay->second);
    overlayCanvas->Clear(flutter::DlColor::kTransparent());
    self.slices[viewId]->render_into(overlayCanvas);
    overlayCanvas->RestoreToCount(restoreCount);

    // This flutter view is never the last in a frame, since we always submit the
    // underlay view last.
    frame->set_submit_info({.frame_boundary = false, .present_with_transaction = true});
    layer->did_submit_last_frame = frame->Encode();

    didEncode &= layer->did_submit_last_frame;
    platformViewLayers[viewId] = LayerData{
        .rect = overlay->second,  //
        .view_id = viewId,        //
        .overlay_id = overlayId,  //
        .layer = layer            //
    };
    surfaceFrames.push_back(std::move(frame));
    overlayId++;
  }

  auto previousSubmitInfo = background_frame->submit_info();
  background_frame->set_submit_info({
      .frame_damage = previousSubmitInfo.frame_damage,
      .buffer_damage = previousSubmitInfo.buffer_damage,
      .present_with_transaction = true,
  });
  background_frame->Encode();
  surfaceFrames.push_back(std::move(background_frame));

  // Mark all layers as available, so they can be used in the next frame.
  std::vector<std::shared_ptr<flutter::OverlayLayer>> unusedLayers =
      self.layerPool->RemoveUnusedLayers();
  self.layerPool->RecycleLayers();

  auto task = [self,                                                      //
               platformViewLayers = std::move(platformViewLayers),        //
               currentCompositionParams = self.currentCompositionParams,  //
               viewsToRecomposite = self.viewsToRecomposite,              //
               compositionOrder = self.compositionOrder,                  //
               unusedLayers = std::move(unusedLayers),                    //
               surfaceFrames = std::move(surfaceFrames)                   //
  ]() mutable {
    [self performSubmit:platformViewLayers
        currentCompositionParams:currentCompositionParams
              viewsToRecomposite:viewsToRecomposite
                compositionOrder:compositionOrder
                    unusedLayers:unusedLayers
                   surfaceFrames:surfaceFrames];
  };

  fml::TaskRunner::RunNowOrPostTask(self.platformTaskRunner, fml::MakeCopyable(std::move(task)));

  return didEncode;
}

- (void)createMissingOverlays:(size_t)requiredOverlayLayers
               withIosContext:(const std::shared_ptr<flutter::IOSContext>&)iosContext {
  TRACE_EVENT0("flutter", "PlatformViewsController::CreateMissingLayers");

  if (requiredOverlayLayers <= self.layerPool->size()) {
    return;
  }
  auto missingLayerCount = requiredOverlayLayers - self.layerPool->size();

  // If the raster thread isn't merged, create layers on the platform thread and block until
  // complete.
  auto latch = std::make_shared<fml::CountDownLatch>(1u);
  fml::TaskRunner::RunNowOrPostTask(
      self.platformTaskRunner, [self, missingLayerCount, iosContext, latch]() {
        for (auto i = 0u; i < missingLayerCount; i++) {
          [self createLayerWithIosContext:iosContext
                              pixelFormat:((FlutterView*)self.flutterView).pixelFormat];
        }
        latch->CountDown();
      });
  if (![[NSThread currentThread] isMainThread]) {
    latch->Wait();
  }
}

- (void)performSubmit:(const LayersMap&)platformViewLayers
    currentCompositionParams:
        (std::unordered_map<int64_t, flutter::EmbeddedViewParams>&)currentCompositionParams
          viewsToRecomposite:(const std::unordered_set<int64_t>&)viewsToRecomposite
            compositionOrder:(const std::vector<int64_t>&)compositionOrder
                unusedLayers:
                    (const std::vector<std::shared_ptr<flutter::OverlayLayer>>&)unusedLayers
               surfaceFrames:
                   (const std::vector<std::unique_ptr<flutter::SurfaceFrame>>&)surfaceFrames {
  TRACE_EVENT0("flutter", "PlatformViewsController::PerformSubmit");
  FML_DCHECK([[NSThread currentThread] isMainThread]);

  [CATransaction begin];

  // Configure Flutter overlay views.
  for (const auto& [viewId, layerData] : platformViewLayers) {
    layerData.layer->UpdateViewState(self.flutterView,     //
                                     layerData.rect,       //
                                     layerData.view_id,    //
                                     layerData.overlay_id  //
    );
  }

  // Dispose unused Flutter Views.
  for (auto& view : [self computeViewsToDispose]) {
    [view removeFromSuperview];
  }

  // Composite Platform Views.
  for (int64_t viewId : viewsToRecomposite) {
    [self compositeView:viewId withParams:currentCompositionParams[viewId]];
  }

  // Present callbacks.
  for (const auto& frame : surfaceFrames) {
    frame->Submit();
  }

  // If a layer was allocated in the previous frame, but it's not used in the current frame,
  // then it can be removed from the scene.
  [self removeUnusedLayers:unusedLayers withCompositionOrder:compositionOrder];

  // Organize the layers by their z indexes.
  [self bringLayersIntoView:platformViewLayers withCompositionOrder:compositionOrder];

  [CATransaction commit];
}

- (void)bringLayersIntoView:(const LayersMap&)layerMap
       withCompositionOrder:(const std::vector<int64_t>&)compositionOrder {
  FML_DCHECK(self.flutterView);
  UIView* flutterView = self.flutterView;

  self.previousCompositionOrder.clear();
  NSMutableArray* desiredPlatformSubviews = [NSMutableArray array];
  for (int64_t platformViewId : compositionOrder) {
    self.previousCompositionOrder.push_back(platformViewId);
    UIView* platformViewRoot = self.platformViews[platformViewId].root_view;
    if (platformViewRoot != nil) {
      [desiredPlatformSubviews addObject:platformViewRoot];
    }

    auto maybeLayerData = layerMap.find(platformViewId);
    if (maybeLayerData != layerMap.end()) {
      auto view = maybeLayerData->second.layer->overlay_view_wrapper;
      if (view != nil) {
        [desiredPlatformSubviews addObject:view];
      }
    }
  }

  NSSet* desiredPlatformSubviewsSet = [NSSet setWithArray:desiredPlatformSubviews];
  NSArray* existingPlatformSubviews = [flutterView.subviews
      filteredArrayUsingPredicate:[NSPredicate
                                      predicateWithBlock:^BOOL(id object, NSDictionary* bindings) {
                                        return [desiredPlatformSubviewsSet containsObject:object];
                                      }]];

  // Manipulate view hierarchy only if needed, to address a performance issue where
  // this method is called even when view hierarchy stays the same.
  // See: https://github.com/flutter/flutter/issues/121833
  // TODO(hellohuanlin): investigate if it is possible to skip unnecessary bringLayersIntoView.
  if (![desiredPlatformSubviews isEqualToArray:existingPlatformSubviews]) {
    for (UIView* subview in desiredPlatformSubviews) {
      // `addSubview` will automatically reorder subview if it is already added.
      [flutterView addSubview:subview];
    }
  }
}

- (std::shared_ptr<flutter::OverlayLayer>)nextLayerInPool {
  return self.layerPool->GetNextLayer();
}

- (void)createLayerWithIosContext:(const std::shared_ptr<flutter::IOSContext>&)iosContext
                      pixelFormat:(MTLPixelFormat)pixelFormat {
  self.layerPool->CreateLayer(iosContext, pixelFormat);
}

- (void)removeUnusedLayers:(const std::vector<std::shared_ptr<flutter::OverlayLayer>>&)unusedLayers
      withCompositionOrder:(const std::vector<int64_t>&)compositionOrder {
  for (const std::shared_ptr<flutter::OverlayLayer>& layer : unusedLayers) {
    [layer->overlay_view_wrapper removeFromSuperview];
  }

  std::unordered_set<int64_t> compositionOrderSet;
  for (int64_t viewId : compositionOrder) {
    compositionOrderSet.insert(viewId);
  }
  // Remove unused platform views.
  for (int64_t viewId : self.previousCompositionOrder) {
    if (compositionOrderSet.find(viewId) == compositionOrderSet.end()) {
      UIView* platformViewRoot = self.platformViews[viewId].root_view;
      [platformViewRoot removeFromSuperview];
    }
  }
}

- (std::vector<UIView*>)computeViewsToDispose {
  std::vector<UIView*> views;
  if (self.viewsToDispose.empty()) {
    return views;
  }

  std::unordered_set<int64_t> viewsToComposite(self.compositionOrder.begin(),
                                               self.compositionOrder.end());
  std::unordered_set<int64_t> viewsToDelayDispose;
  for (int64_t viewId : self.viewsToDispose) {
    if (viewsToComposite.count(viewId)) {
      viewsToDelayDispose.insert(viewId);
      continue;
    }
    UIView* rootView = self.platformViews[viewId].root_view;
    views.push_back(rootView);
    self.currentCompositionParams.erase(viewId);
    self.viewsToRecomposite.erase(viewId);
    self.platformViews.erase(viewId);
  }
  self.viewsToDispose = std::move(viewsToDelayDispose);
  return views;
}

- (void)resetFrameState {
  self.slices.clear();
  self.compositionOrder.clear();
  self.visitedPlatformViews.clear();
}

- (void)pushVisitedPlatformViewId:(int64_t)viewId {
  self.visitedPlatformViews.push_back(viewId);
}

- (const flutter::EmbeddedViewParams&)compositionParamsForView:(int64_t)viewId {
  return self.currentCompositionParams.find(viewId)->second;
}

#pragma mark - Properties

- (flutter::OverlayLayerPool*)layerPool {
  return _layerPool.get();
}

- (std::unordered_map<int64_t, std::unique_ptr<flutter::EmbedderViewSlice>>&)slices {
  return _slices;
}

- (std::unordered_map<std::string, NSObject<FlutterPlatformViewFactory>*>&)factories {
  return _factories;
}
- (std::unordered_map<std::string, FlutterPlatformViewGestureRecognizersBlockingPolicy>&)
    gestureRecognizersBlockingPolicies {
  return _gestureRecognizersBlockingPolicies;
}

- (std::unordered_map<int64_t, PlatformViewData>&)platformViews {
  return _platformViews;
}

- (std::unordered_map<int64_t, flutter::EmbeddedViewParams>&)currentCompositionParams {
  return _currentCompositionParams;
}

- (std::unordered_set<int64_t>&)viewsToDispose {
  return _viewsToDispose;
}

- (std::vector<int64_t>&)compositionOrder {
  return _compositionOrder;
}

- (std::vector<int64_t>&)visitedPlatformViews {
  return _visitedPlatformViews;
}

- (std::unordered_set<int64_t>&)viewsToRecomposite {
  return _viewsToRecomposite;
}

- (std::vector<int64_t>&)previousCompositionOrder {
  return _previousCompositionOrder;
}

@end
