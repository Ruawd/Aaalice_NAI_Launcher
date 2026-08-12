import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../core/utils/localization_extension.dart';
import '../../../data/models/gallery/local_image_record.dart';
import '../../utils/local_image_aspect_ratio.dart';
import 'draggable_image_card.dart';
import 'local_image_card_3d.dart';
import 'local_image_context_menu.dart';

class ResponsiveLayout {
  ResponsiveLayout._();

  static const double fixedCardWidth = 180;
  static const double fixedCardHeight = 220;

  static int calculateColumns(
    double screenWidth, {
    double spacing = 12,
    double padding = 16,
  }) {
    final availableWidth = screenWidth - padding * 2;
    final columns = ((availableWidth + spacing) / (fixedCardWidth + spacing))
        .floor();
    return columns.clamp(2, 8);
  }

  static double calculateGridWidth(int columns, {double spacing = 12}) {
    return columns * fixedCardWidth + (columns - 1) * spacing;
  }
}

enum _ScrollDirection { idle, up, down }

class GalleryGrid extends StatefulWidget {
  final List<LocalImageRecord> images;
  final int columns;
  final double spacing;
  final EdgeInsets padding;
  final void Function(LocalImageRecord record, int index)? onTap;
  final void Function(LocalImageRecord record, int index)? onDoubleTap;
  final void Function(LocalImageRecord record, int index)? onLongPress;
  final void Function(
    LocalImageRecord record,
    int index,
    TapDownDetails details,
  )?
  onSecondaryTapDown;
  final void Function(LocalImageRecord record, int index)? onFavoriteToggle;
  final void Function(LocalImageRecord record, int index)? onDelete;
  final Future<void> Function(
    LocalImageRecord record,
    int index,
    LocalImageContextAction action,
  )?
  onAction;
  final Future<void> Function(
    LocalImageRecord record,
    int index,
    LocalImageContextAction action,
  )?
  onSendAction;
  final bool isKritaConnected;
  final Set<int>? selectedIndices;
  final double preloadScreens;
  final bool enableDrag;

  const GalleryGrid({
    super.key,
    required this.images,
    this.columns = 4,
    this.spacing = 12,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.onFavoriteToggle,
    this.onDelete,
    this.onAction,
    this.onSendAction,
    this.isKritaConnected = false,
    this.selectedIndices,
    this.preloadScreens = 2.0,
    this.enableDrag = true,
  });

  @override
  State<GalleryGrid> createState() => _GalleryGridState();
}

class _GalleryGridState extends State<GalleryGrid> {
  final Map<String, double> _aspectRatioCache = {};
  final Map<String, Future<double>> _aspectRatioLoads = {};
  final Set<int> _visibleIndices = {};
  final Set<int> _preloadIndices = {};
  late final ScrollController _scrollController;
  _ScrollDirection _scrollDirection = _ScrollDirection.idle;
  double _lastScrollOffset = 0;
  double _viewportHeight = 0;
  double _itemWidth = ResponsiveLayout.fixedCardWidth;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(GalleryGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 图片列表变化时清理索引（如翻页时）
    if (oldWidget.images.length != widget.images.length ||
        (oldWidget.images.isNotEmpty &&
            widget.images.isNotEmpty &&
            oldWidget.images.first.path != widget.images.first.path)) {
      _visibleIndices.clear();
      _preloadIndices.clear();
      final currentPaths = widget.images.map((record) => record.path).toSet();
      _aspectRatioCache.removeWhere((path, _) => !currentPaths.contains(path));
      _aspectRatioLoads.removeWhere((path, _) => !currentPaths.contains(path));
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final currentOffset = _scrollController.offset;
    if (currentOffset > _lastScrollOffset) {
      _scrollDirection = _ScrollDirection.down;
    } else if (currentOffset < _lastScrollOffset) {
      _scrollDirection = _ScrollDirection.up;
    } else {
      _scrollDirection = _ScrollDirection.idle;
    }
    _lastScrollOffset = currentOffset;
  }

  int _getPriority(int index) {
    if (_visibleIndices.contains(index)) return 1;
    if (_preloadIndices.contains(index)) return 3;
    return 10;
  }

  double _getAspectRatio(LocalImageRecord record) {
    final cached = _aspectRatioCache[record.path];
    if (cached != null) return cached;

    _aspectRatioLoads.putIfAbsent(record.path, () {
      final future = readLocalImageAspectRatio(record);
      future.then((aspectRatio) {
        if (identical(_aspectRatioLoads[record.path], future)) {
          _aspectRatioLoads.remove(record.path);
        }
        if (!mounted ||
            !widget.images.any((item) => item.path == record.path)) {
          return;
        }
        if (_aspectRatioCache[record.path] != aspectRatio) {
          setState(() => _aspectRatioCache[record.path] = aspectRatio);
        }
      });
      return future;
    });

    return 1.0;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_not_supported, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              context.l10n.localGallery_noImagesFound,
              style: const TextStyle(color: Colors.grey, fontSize: 16),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportHeight = constraints.maxHeight;
        final columns = widget.columns;
        final horizontalPadding = widget.padding.horizontal;
        final availableWidth =
            constraints.maxWidth -
            horizontalPadding -
            (columns - 1) * widget.spacing;
        final itemWidth = availableWidth / columns;
        _itemWidth = itemWidth;

        return CustomScrollView(
          controller: _scrollController,
          primary: false,
          // 限制缓存范围，减少内存占用和重建开销
          scrollCacheExtent: ScrollCacheExtent.pixels(
            _viewportHeight * widget.preloadScreens,
          ),
          slivers: [
            SliverPadding(
              padding: widget.padding,
              sliver: SliverMasonryGrid.count(
                crossAxisCount: columns,
                mainAxisSpacing: widget.spacing,
                crossAxisSpacing: widget.spacing,
                childCount: widget.images.length,
                itemBuilder: (context, index) {
                  final record = widget.images[index];
                  final aspectRatio = _getAspectRatio(record);
                  final itemHeight = itemWidth / aspectRatio;
                  final isSelected =
                      widget.selectedIndices?.contains(index) ?? false;
                  final isVisible = _visibleIndices.contains(index);
                  final priority = _getPriority(index);

                  return VisibilityDetector(
                    key: ValueKey('v_${record.path}'),
                    onVisibilityChanged: (info) {
                      // 检查 mounted 避免 dispose 后调用 setState
                      if (!mounted) return;

                      final isNowVisible = info.visibleFraction > 0.05;
                      final wasVisible = _visibleIndices.contains(index);

                      if (isNowVisible != wasVisible) {
                        setState(() {
                          if (isNowVisible) {
                            _visibleIndices.add(index);
                          } else {
                            _visibleIndices.remove(index);
                          }
                        });
                        if (isNowVisible) _updatePreloadRange(index);
                      }
                    },
                    child: RepaintBoundary(
                      child: _GalleryImageCard(
                        key: ValueKey(record.path),
                        record: record,
                        width: itemWidth,
                        height: itemHeight,
                        isSelected: isSelected,
                        isVisible: isVisible,
                        priority: priority,
                        enableDrag: widget.enableDrag,
                        onTap: () => widget.onTap?.call(record, index),
                        onDoubleTap: () =>
                            widget.onDoubleTap?.call(record, index),
                        onLongPress: () =>
                            widget.onLongPress?.call(record, index),
                        onSecondaryTapDown: (details) => widget
                            .onSecondaryTapDown
                            ?.call(record, index, details),
                        onFavoriteToggle: widget.onFavoriteToggle != null
                            ? () => widget.onFavoriteToggle!(record, index)
                            : null,
                        onDelete: widget.onDelete != null
                            ? () => widget.onDelete!(record, index)
                            : null,
                        onAction: widget.onAction != null
                            ? (action) =>
                                  widget.onAction!(record, index, action)
                            : null,
                        onSendAction: widget.onSendAction != null
                            ? (action) =>
                                  widget.onSendAction!(record, index, action)
                            : null,
                        isKritaConnected: widget.isKritaConnected,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _updatePreloadRange(int visibleIndex) {
    final itemsPerRow = widget.columns;
    final averageItemHeight = _aspectRatioCache.values.isEmpty
        ? ResponsiveLayout.fixedCardHeight
        : _itemWidth /
              (_aspectRatioCache.values.reduce((a, b) => a + b) /
                  _aspectRatioCache.length);
    final rowsPerScreen = (_viewportHeight / averageItemHeight).ceil().clamp(
      2,
      10,
    );
    final itemsPerScreen = itemsPerRow * rowsPerScreen;
    final preloadCount = (itemsPerScreen * widget.preloadScreens).round();

    final (
      int forwardPreload,
      int backwardPreload,
    ) = switch (_scrollDirection) {
      _ScrollDirection.down => (preloadCount, preloadCount ~/ 3),
      _ScrollDirection.up => (preloadCount ~/ 3, preloadCount),
      _ScrollDirection.idle => (preloadCount, preloadCount ~/ 2),
    };

    final newPreloadIndices = <int>{};

    for (var i = visibleIndex - backwardPreload; i < visibleIndex; i++) {
      if (i >= 0 && i < widget.images.length) newPreloadIndices.add(i);
    }

    for (var i = visibleIndex + 1; i <= visibleIndex + forwardPreload; i++) {
      if (i >= 0 && i < widget.images.length) newPreloadIndices.add(i);
    }

    if ((_preloadIndices.difference(newPreloadIndices).isNotEmpty ||
            newPreloadIndices.difference(_preloadIndices).isNotEmpty) &&
        mounted) {
      setState(() {
        _preloadIndices
          ..clear()
          ..addAll(newPreloadIndices);
      });
    }
  }
}

class _GalleryImageCard extends StatefulWidget {
  final LocalImageRecord record;
  final double width;
  final double height;
  final bool isSelected;
  final bool isVisible;
  final int priority;
  final bool enableDrag;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onLongPress;
  final void Function(TapDownDetails)? onSecondaryTapDown;
  final VoidCallback? onFavoriteToggle;
  final VoidCallback? onDelete;
  final Future<void> Function(LocalImageContextAction action)? onAction;
  final Future<void> Function(LocalImageContextAction action)? onSendAction;
  final bool isKritaConnected;

  const _GalleryImageCard({
    super.key,
    required this.record,
    required this.width,
    required this.height,
    this.isSelected = false,
    this.isVisible = false,
    this.priority = 5,
    this.enableDrag = true,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.onFavoriteToggle,
    this.onDelete,
    this.onAction,
    this.onSendAction,
    this.isKritaConnected = false,
  });

  @override
  State<_GalleryImageCard> createState() => _GalleryImageCardState();
}

class _GalleryImageCardState extends State<_GalleryImageCard> {
  @override
  Widget build(BuildContext context) {
    return LocalImageCard3D(
      record: widget.record,
      width: widget.width,
      height: widget.height,
      isSelected: widget.isSelected,
      isVisible: widget.isVisible,
      priority: widget.priority,
      onTap: widget.onTap,
      onDoubleTap: widget.onDoubleTap,
      onLongPress: widget.onLongPress,
      onSecondaryTapDown: widget.onSecondaryTapDown,
      onFavoriteToggle: widget.onFavoriteToggle,
      onDelete: widget.onDelete,
      onAction: widget.onAction,
      onSendAction: widget.onSendAction,
      isKritaConnected: widget.isKritaConnected,
      // 使用 dragWrapper 将拖拽功能注入到卡片内部
      // 解决 GestureDetector 与拖拽手势的冲突问题
      dragWrapper:
          widget.enableDrag && MediaQuery.sizeOf(context).shortestSide >= 600
          ? DraggableImageCard.createDragWrapper(record: widget.record)
          : null,
    );
  }
}
