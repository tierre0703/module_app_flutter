// lib/widgets/reorderable_tile_grid.dart
//
// A responsive tile grid that arranges children in a Wrap layout with a
// configurable number of columns (default 2 on narrow, 4 on wide).
//
// Reordering: uses LongPressDraggable + DragTarget. Each tile has a drag
// handle at the top-left corner.
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
/// Reordering: long-press the drag handle on any tile to reorder.
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
              child: SizedBox(
                width: tileWidth,
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
                            child: children[i],
                          ),
                        ),
                        childWhenDragging: children[i],
                        child: children[i],
                      ),
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
}