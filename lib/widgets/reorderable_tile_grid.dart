// lib/widgets/reorderable_tile_grid.dart
//
// A responsive tile grid that arranges children in a Wrap layout with a
// configurable number of columns (default 2 on narrow, 4 on wide), and
// supports drag-and-drop reordering.
//
// When [dragHandleBuilder] is provided, each tile gets a dedicated drag
// handle (positioned at the top-left of the tile) and dragging starts
// immediately from that handle - no long press required. Without a handle
// the whole tile is draggable via long press.
import 'package:flutter/material.dart';

typedef ReorderItemCallback = void Function(int oldIndex, int newIndex);

/// Builds the drag handle for the tile at [index].
typedef DragHandleBuilder = Widget Function(BuildContext context, int index);

class ReorderableTileGrid extends StatefulWidget {
  const ReorderableTileGrid({
    super.key,
    required this.children,
    required this.onReorderItem,
    this.dragHandleBuilder,
    this.spacing = 12,
    this.runSpacing = 12,
    this.narrowColumns = 2,
    this.wideColumns = 4,
    this.breakpoint = 600,
    this.padding,
  });

  final List<Widget> children;
  final ReorderItemCallback onReorderItem;

  /// Optional per-tile drag handle. When set, only the handle starts a drag
  /// (immediate drag, no long press) and it is placed at the tile's
  /// top-left corner.
  final DragHandleBuilder? dragHandleBuilder;

  final double spacing;
  final double runSpacing;
  final int narrowColumns;
  final int wideColumns;
  final double breakpoint;
  final EdgeInsets? padding;

  @override
  State<ReorderableTileGrid> createState() => _ReorderableTileGridState();
}

class _ReorderableTileGridState extends State<ReorderableTileGrid> {
  double _containerWidth = 0;

  int get _columns {
    if (_containerWidth < widget.breakpoint) return widget.narrowColumns;
    return widget.wideColumns;
  }

  int _hoverTargetIndex = -1;
  int _dragSourceIndex = -1;

  void _startDrag(int index) {
    setState(() => _dragSourceIndex = index);
  }

  void _endDrag() {
    if (_dragSourceIndex < 0 && _hoverTargetIndex < 0) return;
    setState(() {
      _dragSourceIndex = -1;
      _hoverTargetIndex = -1;
    });
  }

  void _drop(int from, int to) {
    if (from != to && from >= 0 && to >= 0) {
      widget.onReorderItem(from, to);
    }
    _endDrag();
  }

  @override
  Widget build(BuildContext context) {
    final children = widget.children;
    if (children.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;

    return LayoutBuilder(builder: (context, constraints) {
      _containerWidth = constraints.maxWidth;
      final columns = _columns;
      final spacing = widget.spacing;
      final runSpacing = widget.runSpacing;
      final paddingH = widget.padding?.horizontal ?? 0;
      final tileWidth =
          (constraints.maxWidth - spacing * (columns - 1) - paddingH) / columns;

      return Padding(
        padding: widget.padding ?? EdgeInsets.zero,
        child: Wrap(
          spacing: spacing,
          runSpacing: runSpacing,
          children: List.generate(children.length, (i) {
            final isHoverTarget = i == _hoverTargetIndex &&
                i != _dragSourceIndex && _dragSourceIndex >= 0;
            final isDragSource = i == _dragSourceIndex;

            return Padding(
              key: ValueKey('tile_$i'),
              padding: EdgeInsets.only(
                  bottom: i + columns < children.length ? runSpacing : 0),
              child: SizedBox(
                width: tileWidth,
                child: DragTarget<int>(
                  onWillAcceptWithDetails: (details) {
                    setState(() => _hoverTargetIndex = i);
                    return true;
                  },
                  onLeave: (_) {
                    if (_hoverTargetIndex == i) {
                      setState(() => _hoverTargetIndex = -1);
                    }
                  },
                  onAcceptWithDetails: (details) => _drop(details.data, i),
                  builder: (context, candidateData, rejectedData) {
                    // The tile content, dimmed while it is being dragged and
                    // outlined while another tile hovers over it.
                    final Widget content = Opacity(
                      opacity: isDragSource ? 0.35 : 1,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        decoration: isHoverTarget
                            ? BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                    color: cs.primary.withValues(alpha: 0.5),
                                    width: 2),
                              )
                            : null,
                        // Force the card to fill the whole grid cell so no
                        // background gap appears on the right.
                        child: SizedBox(
                          width: tileWidth,
                          child: children[i],
                        ),
                      ),
                    );

                    final handle = widget.dragHandleBuilder;

                    // Without a dedicated handle, fall back to long-press
                    // dragging from anywhere on the tile.
                    if (handle == null) {
                      return LongPressDraggable<int>(
                        data: i,
                        onDragStarted: () => _startDrag(i),
                        onDragEnd: (_) => _endDrag(),
                        feedback: _feedback(context, tileWidth, children[i]),
                        childWhenDragging:
                            Opacity(opacity: 0.35, child: children[i]),
                        child: content,
                      );
                    }

                    // With a handle: only the handle starts the drag, and it
                    // starts immediately (no long press).
                    return Stack(
                      children: [
                        content,
                        Positioned(
                          left: 0,
                          top: 0,
                          child: Draggable<int>(
                            data: i,
                            dragAnchorStrategy: pointerDragAnchorStrategy,
                            onDragStarted: () => _startDrag(i),
                            onDragEnd: (_) => _endDrag(),
                            feedback:
                                _feedback(context, tileWidth, children[i]),
                            childWhenDragging:
                                Opacity(opacity: 0.35, child: handle(context, i)),
                            child: handle(context, i),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            );
          }),
        ),
      );
    });
  }

  /// The widget shown under the finger while dragging a tile.
  Widget _feedback(BuildContext context, double tileWidth, Widget child) {
    return Material(
      elevation: 8,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(width: tileWidth, child: child),
    );
  }
}
