// lib/widgets/reorderable_tile_grid.dart
//
// A responsive tile grid that arranges children in a Wrap layout with a
// configurable number of columns (default 2 on narrow, 4 on wide).
//
// Reordering: each tile has a drag handle. Drag the handle to reorder.
// Uses LongPressDraggable + DragTarget which requires long-press to start
// dragging; the drag handle icon provides the visual affordance.
import 'package:flutter/material.dart';

/// Signature for the reorder callback.
typedef ReorderItemCallback = void Function(int oldIndex, int newIndex);

/// Builder for a per-tile drag handle widget.
typedef DragHandleBuilder = Widget Function(BuildContext context, int index);

/// A responsive tile grid with drag-and-drop reorder support.
///
/// Layout:
/// - Narrow (< [breakpoint]): [narrowColumns] columns (default 2 for phones)
/// - Wide   (>= [breakpoint]): [wideColumns] columns (default 4 for tablets)
///
/// Reordering: long-press the drag handle on any tile to reorder. The
/// [dragHandleBuilder] callback supplies a drag handle widget for each
/// tile (e.g., a drag indicator icon). When omitted, the entire tile acts
/// as the drag initiator.
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

  /// Optional per-tile drag handle widget builder. When provided, the
  /// handle is placed at the top-right of each tile as a drag affordance.
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
  /// The available width from the last layout pass.
  double _containerWidth = 0;

  int get _columns {
    if (_containerWidth < widget.breakpoint) return widget.narrowColumns;
    return widget.wideColumns;
  }

  // Track which tile is currently being hovered over during a drag.
  int _hoverTargetIndex = -1;
  int _dragSourceIndex = -1;

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

            return Padding(
              key: ValueKey('tile_$i'),
              padding: EdgeInsets.only(
                  bottom: i + columns < children.length ? runSpacing : 0),
              child: DragTarget<int>(
                onAcceptWithDetails: (details) {
                  final from = details.data;
                  final to = i;
                  if (from != to && from >= 0 && to >= 0) {
                    widget.onReorderItem(from, to);
                  }
                  setState(() {
                    _dragSourceIndex = -1;
                    _hoverTargetIndex = -1;
                  });
                },
                onWillAcceptWithDetails: (details) {
                  setState(() => _hoverTargetIndex = i);
                  return true;
                },
                onLeave: (_) {
                  setState(() => _hoverTargetIndex = -1);
                },
                builder: (context, candidateData, rejectedData) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    decoration: isHoverTarget
                        ? BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color: cs.primary.withValues(alpha: 0.5),
                                width: 2),
                          )
                        : null,
                    width: tileWidth,
                    child: LongPressDraggable<int>(
                      data: i,
                      onDragStarted: () =>
                          setState(() => _dragSourceIndex = i),
                      onDragEnd: (_) => setState(() {
                        _dragSourceIndex = -1;
                        _hoverTargetIndex = -1;
                      }),
                      feedback: Material(
                        elevation: 8,
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(
                          width: tileWidth,
                          child: Opacity(
                            opacity: 0.85,
                            child: _buildTileContent(context, i, children[i]),
                          ),
                        ),
                      ),
                      childWhenDragging: Opacity(
                        opacity: 0.35,
                        child: _buildTileContent(context, i, children[i]),
                      ),
                      child: _buildTileContent(context, i, children[i]),
                    ),
                  );
                },
              ),
            );
          }),
        ),
      );
    });
  }

  /// Wraps the tile child with a drag handle if one is configured.
  Widget _buildTileContent(BuildContext context, int index, Widget child) {
    final builder = widget.dragHandleBuilder;
    if (builder == null) return child;
    return Stack(
      children: [
        child,
        Positioned(
          right: 4,
          top: 4,
          child: builder(context, index),
        ),
      ],
    );
  }
}