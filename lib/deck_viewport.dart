// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4;

typedef _ChildSizingFunction = double Function(RenderBox child);

/// A delegate used by [RenderDeckViewport] to manage its children.
///
/// [RenderDeckViewport] during layout will ask the delegate to create
/// children that are visible in the viewport and remove those that are not.
abstract class DeckChildManager {
  /// The maximum number of children that can be provided to
  /// [RenderDeckViewport].
  ///
  /// If non-null, the children will have index in the range [0, childCount - 1].
  ///
  /// If null, then there's no explicit limits to the range of the children
  /// except that it has to be contiguous. If [childExistsAt] for a certain
  /// index returns false, that index is already past the limit.
  int get childCount;

  /// Checks whether the delegate is able to provide a child widget at the given
  /// index.
  ///
  /// This function is not about whether the child at the given index is
  /// attached to the [RenderDeckViewport] or not.
  bool childExistsAt(int index);

  /// Creates a new child at the given index and updates it to the child list
  /// of [RenderDeckViewport]. If no child corresponds to `index`, then do
  /// nothing.
  ///
  /// It is possible to create children with negative indices.
  void createChild(int index, {@required RenderBox after});

  /// Removes the child element corresponding with the given RenderBox.
  void removeChild(RenderBox child);
}

/// [ParentData] for use with [RenderDeckViewport].
class DeckParentData extends ContainerBoxParentData<RenderBox> {
  /// Index of this child in its parent's child list.
  int index;
  Matrix4 paintTransform;
}

/// Render, onto a wheel, a bigger sequential set of objects inside this viewport.
///
/// Takes a scrollable set of fixed sized [RenderBox]es and renders them
/// sequentially from top down on a vertical scrolling axis.
///
/// It starts with the first scrollable item in the center of the main axis
/// and ends with the last scrollable item in the center of the main axis. This
/// is in contrast to typical lists that start with the first scrollable item
/// at the start of the main axis and ends with the last scrollable item at the
/// end of the main axis.
///
/// Instead of rendering its children on a flat plane, it renders them
/// as if each child is broken into its own plane and that plane is
/// perpendicularly fixed onto a cylinder which rotates along the scrolling
/// axis.
///
/// This class works in 3 coordinate systems:
///
/// 1. The **scrollable layout coordinates**. This coordinate system is used to
///    communicate with [ViewportOffset] and describes its children's abstract
///    offset from the beginning of the scrollable list at (0.0, 0.0).
///
///    The list is scrollable from the start of the first child item to the
///    start of the last child item.
///
///    Children's layout coordinates don't change as the viewport scrolls.
///
/// 2. The **untransformed plane's viewport painting coordinates**. Children are
///    not painted in this coordinate system. It's an abstract intermediary used
///    before transforming into the next cylindrical coordinate system.
///
///    This system is the **scrollable layout coordinates** translated by the
///    scroll offset such that (0.0, 0.0) is the top left corner of the
///    viewport.
///
///    Because the viewport is centered at the scrollable list's scroll offset
///    instead of starting at the scroll offset, there are paintable children
///    ~1/2 viewport length before and after the scroll offset instead of ~1
///    viewport length after the scroll offset.
///
///    Children's visibility inclusion in the viewport is determined in this
///    system regardless of the cylinder's properties such as [diameterRatio]
///    or [perspective]. In other words, a 100px long viewport will always
///    paint 10-11 visible 10px children if there are enough children in the
///    viewport.
///
/// 3. The **transformed cylindrical space viewport painting coordinates**.
///    Children from system 2 get their positions transformed into a cylindrical
///    projection matrix instead of its Cartesian offset with respect to the
///    scroll offset.
///
///    Children in this coordinate system are painted.
///
///    The wheel's size and the maximum and minimum visible angles are both
///    controlled by [diameterRatio]. Children visible in the **untransformed
///    plane's viewport painting coordinates**'s viewport will be radially
///    evenly laid out between the maximum and minimum angles determined by
///    intersecting the viewport's main axis length with a cylinder whose
///    diameter is [diameterRatio] times longer, as long as those angles are
///    between -pi/2 and pi/2.
///
///    For example, if [diameterRatio] is 2.0 and this [RenderDeckViewport]
///    is 100.0px in the main axis, then the diameter is 200.0. And children
///    will be evenly laid out between that cylinder's -arcsin(1/2) and
///    arcsin(1/2) angles.
///
///    The cylinder's 0 degree side is always centered in the
///    [RenderDeckViewport]. The transformation from **untransformed
///    plane's viewport painting coordinates** is also done such that the child
///    in the center of that plane will be mostly untransformed with children
///    above and below it being transformed more as the angle increases.
class RenderDeckViewport extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, DeckParentData>
    implements RenderAbstractViewport {
  /// Creates a [RenderDeckViewport] which renders children on a wheel.
  ///
  /// All arguments must not be null. Optional arguments have reasonable defaults.
  RenderDeckViewport({
    @required this.childManager,
    @required ViewportOffset offset,
    @required double itemExtent,
    double virtualItemExtent,
    double layoutPow = 4,
    bool clipToSize = true,
    bool renderChildrenOutsideViewport = false,
    List<RenderBox> children,
  })  : assert(childManager != null),
        assert(offset != null),
        assert(layoutPow != null),
        assert(layoutPow > 0),
        assert(itemExtent != null),
        assert(itemExtent > 0),
        assert(clipToSize != null),
        assert(renderChildrenOutsideViewport != null),
        assert(
          !renderChildrenOutsideViewport || !clipToSize,
          clipToSizeAndRenderChildrenOutsideViewportConflict,
        ),
        _offset = offset,
        _layoutPow = layoutPow,
        _itemExtent = itemExtent,
        _virtualItemExtent = virtualItemExtent,
        _clipToSize = clipToSize,
        _renderChildrenOutsideViewport = renderChildrenOutsideViewport {
    addAll(children);
  }
  static const int maxVisibleItemCount = 8;
  static const double firstItemOffsetIndex = 7;
  static const double itemScaleMin = .95;

  /// An error message to show when [clipToSize] and [renderChildrenOutsideViewport]
  /// are set to conflicting values.
  static const String clipToSizeAndRenderChildrenOutsideViewportConflict =
      'Cannot renderChildrenOutsideViewport and clipToSize since children '
      'rendered outside will be clipped anyway.';

  /// The delegate that manages the children of this object.
  final DeckChildManager childManager;

  /// The associated ViewportOffset object for the viewport describing the part
  /// of the content inside that's visible.
  ///
  /// The [ViewportOffset.pixels] value determines the scroll offset that the
  /// viewport uses to select which part of its content to display. As the user
  /// scrolls the viewport, this value changes, which changes the content that
  /// is displayed.
  ///
  /// Must not be null.
  ViewportOffset get offset => _offset;
  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    assert(value != null);
    if (value == _offset) return;
    if (attached) _offset.removeListener(_hasScrolled);
    _offset = value;
    if (attached) _offset.addListener(_hasScrolled);
    markNeedsLayout();
  }

  double get layoutPow => _layoutPow;
  double _layoutPow;
  set layoutPow(double value) {
    assert(value != null);
    assert(value > 0);
    if (value == _layoutPow) return;
    _layoutPow = value;
    markNeedsLayout();
  }

  /// {@template flutter.rendering.wheelList.itemExtent}
  /// The size of the children along the main axis. Children [RenderBox]es will
  /// be given the [BoxConstraints] of this exact size.
  ///
  /// Must not be null and must be positive.
  /// {@endtemplate}
  double get itemExtent => _itemExtent;
  double _itemExtent;
  set itemExtent(double value) {
    assert(value != null);
    assert(value > 0);
    if (value == _itemExtent) return;
    _itemExtent = value;
    markNeedsLayout();
  }

  double get virtualItemExtent =>
      _virtualItemExtent ?? (size.height / maxVisibleItemCount);
  double _virtualItemExtent;
  set virtualItemExtent(double value) {
    if (value == null || value < 0 || value == _virtualItemExtent) return;
    _virtualItemExtent = value;
    markNeedsLayout();
  }

  /// {@template flutter.rendering.wheelList.clipToSize}
  /// Whether to clip painted children to the inside of this viewport.
  ///
  /// Defaults to [true]. Must not be null.
  ///
  /// If this is false and [renderChildrenOutsideViewport] is false, the
  /// first and last children may be painted partly outside of this scroll view.
  /// {@endtemplate}
  bool get clipToSize => _clipToSize;
  bool _clipToSize;
  set clipToSize(bool value) {
    assert(value != null);
    assert(
      !renderChildrenOutsideViewport || !clipToSize,
      clipToSizeAndRenderChildrenOutsideViewportConflict,
    );
    if (value == _clipToSize) return;
    _clipToSize = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  /// {@template flutter.rendering.wheelList.renderChildrenOutsideViewport}
  /// Whether to paint children inside the viewport only.
  ///
  /// If false, every child will be painted. However the [Scrollable] is still
  /// the size of the viewport and detects gestures inside only.
  ///
  /// Defaults to [false]. Must not be null. Cannot be true if [clipToSize]
  /// is also true since children outside the viewport will be clipped, and
  /// therefore cannot render children outside the viewport.
  /// {@endtemplate}
  bool get renderChildrenOutsideViewport => _renderChildrenOutsideViewport;
  bool _renderChildrenOutsideViewport;
  set renderChildrenOutsideViewport(bool value) {
    assert(value != null);
    assert(
      !renderChildrenOutsideViewport || !clipToSize,
      clipToSizeAndRenderChildrenOutsideViewportConflict,
    );
    if (value == _renderChildrenOutsideViewport) return;
    _renderChildrenOutsideViewport = value;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  void _hasScrolled() {
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! DeckParentData)
      child.parentData = DeckParentData();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_hasScrolled);
  }

  @override
  void detach() {
    _offset.removeListener(_hasScrolled);
    super.detach();
  }

  @override
  bool get isRepaintBoundary => true;

  /// Main axis length in the untransformed plane.
  double get _viewportExtent {
    assert(hasSize);
    return size.height;
  }

  /// Main axis scroll extent in the **scrollable layout coordinates** that puts
  /// the first item in the center.
  double get _minEstimatedScrollExtent {
    assert(hasSize);
    if (childManager.childCount == null) return double.negativeInfinity;
    return 0.0;
  }

  /// Main axis scroll extent in the **scrollable layout coordinates** that puts
  /// the last item in the center.
  double get _maxEstimatedScrollExtent {
    assert(hasSize);
    if (childManager.childCount == null) return double.infinity;

    return math.max(0.0, (childManager.childCount - 1) * virtualItemExtent);
  }

  /// Transforms a **scrollable layout coordinates**' y position to the
  /// **untransformed plane's viewport painting coordinates**' y position given
  /// the current scroll offset.
  double _getUntransformedPaintingCoordinateY(double layoutCoordinateY) {
    return layoutCoordinateY - offset.pixels;
  }

  double _getIntrinsicCrossAxis(_ChildSizingFunction childSize) {
    double extent = 0.0;
    RenderBox child = firstChild;
    while (child != null) {
      extent = math.max(extent, childSize(child));
      child = childAfter(child);
    }
    return extent;
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    return _getIntrinsicCrossAxis(
        (RenderBox child) => child.getMinIntrinsicWidth(height));
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    return _getIntrinsicCrossAxis(
        (RenderBox child) => child.getMaxIntrinsicWidth(height));
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    if (childManager.childCount == null) return 0.0;
    return childManager.childCount * virtualItemExtent;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    if (childManager.childCount == null) return 0.0;
    return childManager.childCount * virtualItemExtent;
  }

  @override
  bool get sizedByParent => true;

  @override
  void performResize() {
    size = constraints.biggest;
    if (childCount > 0) {
      RenderBox child = firstChild;
      while (child != null) {
        final parentData = child.parentData;
        if (parentData is DeckParentData) {
          _updateParentDataOffset(parentData, parentData.index);
        }
        child = childAfter(child);
      }
    }
  }

  /// Gets the index of a child by looking at its parentData.
  int indexOf(RenderBox child) {
    assert(child != null);
    final DeckParentData childParentData = child.parentData;
    assert(childParentData.index != null);
    return childParentData.index;
  }

  /// Returns the index of the child at the given offset.
  int scrollOffsetToIndex(double scrollOffset) =>
      (scrollOffset / virtualItemExtent - firstItemOffsetIndex).floor();

  /// Returns the scroll offset of the child with the given index.
  double indexToRealScrollOffset(int index) => (index) * virtualItemExtent;
  double indexToScrollOffset(int index) =>
      (index + firstItemOffsetIndex) * virtualItemExtent;

  void _createChild(int index, {RenderBox after}) {
    invokeLayoutCallback<BoxConstraints>((BoxConstraints constraints) {
      assert(constraints == this.constraints);
      childManager.createChild(index, after: after);
    });
  }

  void _destroyChild(RenderBox child) {
    invokeLayoutCallback<BoxConstraints>((BoxConstraints constraints) {
      assert(constraints == this.constraints);
      childManager.removeChild(child);
    });
  }

  void _layoutChild(RenderBox child, BoxConstraints constraints, int index) {
    child.layout(constraints, parentUsesSize: true);
    final DeckParentData childParentData = child.parentData;
    _updateParentDataOffset(childParentData, index);
  }

  void _updateParentDataOffset(DeckParentData childParentData, int index) {
    childParentData.offset = Offset(0, indexToScrollOffset(index));
  }

  /// Performs layout based on how [childManager] provides children.
  ///
  /// From the current scroll offset, the minimum index and maximum index that
  /// is visible in the viewport can be calculated. The index range of the
  /// currently active children can also be acquired by looking directly at
  /// the current child list. This function has to modify the current index
  /// range to match the target index range by removing children that are no
  /// longer visible and creating those that are visible but not yet provided
  /// by [childManager].
  @override
  void performLayout() {
    final BoxConstraints childConstraints = constraints.copyWith(
      minHeight: itemExtent,
      maxHeight: itemExtent,
      minWidth: 0.0,
    );

    // The height, in pixel, that children will be visible and might be laid out
    // and painted.
    double visibleHeight = size.height;
    // If renderChildrenOutsideViewport is true, we spawn extra children by
    // doubling the visibility range, those that are in the backside of the
    // cylinder won't be painted anyway.
    if (renderChildrenOutsideViewport) visibleHeight *= 2;

    final double firstVisibleOffset = offset.pixels;
    final double lastVisibleOffset = firstVisibleOffset + visibleHeight;

    // The index range that we want to spawn children. We find indexes that
    // are in the interval [firstVisibleOffset, lastVisibleOffset).
    int targetFirstIndex = scrollOffsetToIndex(firstVisibleOffset);
    int realTargetFirstIndex =
        targetFirstIndex.clamp(0, targetFirstIndex.abs());

    int targetLastIndex = scrollOffsetToIndex(lastVisibleOffset);
    // Because we exclude lastVisibleOffset, if there's a new child starting at
    // that offset, it is removed.
    if (targetLastIndex * virtualItemExtent == lastVisibleOffset)
      targetLastIndex--;

    // Validates the target index range.
    while (!childManager.childExistsAt(targetFirstIndex) &&
        targetFirstIndex <= targetLastIndex) targetFirstIndex++;
    while (((targetLastIndex + firstItemOffsetIndex) * virtualItemExtent -
                firstVisibleOffset) >
            visibleHeight ||
        (!childManager.childExistsAt(targetLastIndex) &&
            targetFirstIndex <= targetLastIndex)) targetLastIndex--;

    // If it turns out there's no children to layout, we remove old children and
    // return.
    if (targetFirstIndex > targetLastIndex) {
      while (firstChild != null) _destroyChild(firstChild);
      return;
    }

    // Now there are 2 cases:
    //  - The target index range and our current index range have intersection:
    //    We shorten and extend our current child list so that the two lists
    //    match. Most of the time we are in this case.
    //  - The target list and our current child list have no intersection:
    //    We first remove all children and then add one child from the target
    //    list => this case becomes the other case.

    // Case when there is no intersection.
    if (childCount > 0 &&
        (indexOf(firstChild) > targetLastIndex ||
            indexOf(lastChild) < realTargetFirstIndex)) {
      while (firstChild != null) _destroyChild(firstChild);
    }

    // If there is no child at this stage, we add the first one that is in
    // target range.
    if (childCount == 0) {
      _createChild(targetFirstIndex);
      _layoutChild(firstChild, childConstraints, targetFirstIndex);
    }

    int currentFirstIndex = indexOf(firstChild);
    int currentLastIndex = indexOf(lastChild);

    // Remove all unnecessary children by shortening the current child list, in
    // both directions.
    // while (currentFirstIndex < targetFirstIndex) {
    while (currentFirstIndex < realTargetFirstIndex) {
      _destroyChild(firstChild);
      currentFirstIndex++;
    }
    while (currentLastIndex > targetLastIndex) {
      _destroyChild(lastChild);
      currentLastIndex--;
    }

    // Relayout all active children.
    RenderBox child = firstChild;
    while (child != null) {
      child.layout(childConstraints, parentUsesSize: true);
      child = childAfter(child);
    }

    // Spawning new children that are actually visible but not in child list yet.
    while (currentFirstIndex > realTargetFirstIndex) {
      _createChild(currentFirstIndex - 1);
      _layoutChild(firstChild, childConstraints, --currentFirstIndex);
    }
    while (currentLastIndex < targetLastIndex) {
      _createChild(currentLastIndex + 1, after: lastChild);
      _layoutChild(lastChild, childConstraints, ++currentLastIndex);
    }

    offset.applyViewportDimension(_viewportExtent);

    // Applying content dimensions bases on how the childManager builds widgets:
    // if it is available to provide a child just out of target range, then
    // we don't know whether there's a limit yet, and set the dimension to the
    // estimated value. Otherwise, we set the dimension limited to our target
    // range.
    final double minScrollExtent =
        childManager.childExistsAt(targetFirstIndex - 1)
            ? _minEstimatedScrollExtent
            : indexToRealScrollOffset(realTargetFirstIndex);
    final double maxScrollExtent =
        childManager.childExistsAt(targetLastIndex + 1)
            ? _maxEstimatedScrollExtent
            : indexToRealScrollOffset(targetLastIndex);
    offset.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }

  bool _shouldClipAtCurrentOffset() {
    final double highestUntransformedPaintY =
        _getUntransformedPaintingCoordinateY(0.0);
    return highestUntransformedPaintY < 0.0 ||
        size.height <
            highestUntransformedPaintY +
                _maxEstimatedScrollExtent +
                virtualItemExtent;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (childCount > 0) {
      if (_clipToSize && _shouldClipAtCurrentOffset()) {
        context.pushClipRect(
          needsCompositing,
          offset,
          Offset.zero & size,
          _paintVisibleChildren,
        );
      } else {
        _paintVisibleChildren(context, offset);
      }
    }
  }

  /// Paints all children visible in the current viewport.
  void _paintVisibleChildren(PaintingContext context, Offset offset) {
    RenderBox childToPaint = firstChild;
    DeckParentData childParentData = childToPaint?.parentData;

    while (childParentData != null) {
      final matrix4 = _paintTransformedChild(
          childToPaint, context, offset, childParentData.offset);
      if (childParentData != null) {
        childParentData.paintTransform = matrix4;
      }
      childToPaint = childAfter(childToPaint);
      childParentData = childToPaint?.parentData;
    }
  }

  /// Takes in a child with a **scrollable layout offset** and paints it in the
  /// **transformed cylindrical space viewport painting coordinates**.
  Matrix4 _paintTransformedChild(
    RenderBox child,
    PaintingContext context,
    Offset offset,
    Offset layoutOffset,
  ) {
    final Offset untransformedPaintingCoordinates = offset +
        Offset(
          layoutOffset.dx,
          _getUntransformedPaintingCoordinateY(layoutOffset.dy),
        );

    // Get child's center as a fraction of the viewport's height.
    var visibleHeight = size.height;
    var visibleWidth = size.width;
    double fractionalY = (untransformedPaintingCoordinates.dy) / visibleHeight;
    if (fractionalY > 1) {
      fractionalY = 1;
    }
    if (fractionalY < 0.0) {
      fractionalY = 0.0;
    }
    // Don't paint the backside of the cylinder when
    // renderChildrenOutsideViewport is true. Otherwise, only children within
    // suitable angles (via _first/lastVisibleLayoutOffset) reach the paint
    // phase.
    // if (angle > math.pi / 2.0 || angle < -math.pi / 2.0) return;

    // final Offset offsetToTop = Offset(untransformedPaintingCoordinates.dx, untransformedPaintingCoordinates.dy);
    var scale = (itemScaleMin + (1 - itemScaleMin) * fractionalY);
    final matrix4 = Matrix4.translationValues(visibleWidth / 2 * (1 - scale),
        math.pow(fractionalY, layoutPow) * visibleHeight, 1)
      ..scale(scale, scale);
    context.pushTransform(
      true,
      offset,
      matrix4,
      // Pre-transform painting function.
      (PaintingContext context, Offset offset) {
        context.paintChild(
          child,
          // Paint everything in the center (e.g. angle = 0), then transform.
          offset,
        );
      },
    );
    return matrix4;
  }

  /// This returns the matrices relative to the **untransformed plane's viewport
  /// painting coordinates** system.
  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final DeckParentData parentData = child?.parentData;
    transform.multiply(parentData.paintTransform);
    // transform.translate(0.0, _getUntransformedPaintingCoordinateY(parentData.offset.dy));
  }

  @override
  Rect describeApproximatePaintClip(RenderObject child) {
    if (child != null && _shouldClipAtCurrentOffset()) {
      return Offset.zero & size;
    }
    return null;
  }

  @override
  bool hitTestChildren(HitTestResult result, {Offset position}) {
    if (result is BoxHitTestResult) {
      var child = lastChild;
      while (child != null) {
        var parentData = child?.parentData;
        if (parentData is DeckParentData) {
          final transform = parentData.paintTransform;
          final bool isHit = result.addWithPaintTransform(
            transform: transform,
            position: position,
            hitTest: (BoxHitTestResult result, Offset position) {
              return child.hitTest(result, position: position);
            },
          );
          if (isHit) {
            return true;
          }
        }
        child = childBefore(child);
      }
    }
    return false;
  }

  @override
  RevealedOffset getOffsetToReveal(RenderObject target, double alignment,
      {Rect rect}) {
    // `target` is only fully revealed when in the selected/center position. Therefore,
    // this method always returns the offset that shows `target` in the center position,
    // which is the same offset for all `alignment` values.

    rect ??= target.paintBounds;

    // `child` will be the last RenderObject before the viewport when walking up from `target`.
    RenderObject child = target;
    while (child.parent != this) child = child.parent;

    final DeckParentData parentData = child.parentData;
    final double targetOffset =
        parentData.offset.dy; // the so-called "centerPosition"

    final Matrix4 transform = target.getTransformTo(this);
    final Rect bounds = MatrixUtils.transformRect(transform, rect);

    return RevealedOffset(offset: targetOffset, rect: bounds);
  }

  @override
  void showOnScreen({
    RenderObject descendant,
    Rect rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    if (descendant != null) {
      // Shows the descendant in the selected/center position.
      final RevealedOffset revealedOffset =
          getOffsetToReveal(descendant, 0.5, rect: rect);
      if (duration == Duration.zero) {
        offset.jumpTo(revealedOffset.offset);
      } else {
        offset.animateTo(revealedOffset.offset,
            duration: duration, curve: curve);
      }
      rect = revealedOffset.rect;
    }

    super.showOnScreen(
      rect: rect,
      duration: duration,
      curve: curve,
    );
  }
}
