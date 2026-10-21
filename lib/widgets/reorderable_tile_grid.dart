// lib/widgets/reorderable_tile_grid.dart
//
// A responsive tile grid that arranges children in a Wrap layout with a
// configurable number of columns (default 2 on narrow, 4 on wide).
//
// Reordering: long-press a tile to "pick it up" (visually indicated by a
// border ring), then tap another tile to swap positions. The picked tile
// is indicated by a primary-colored border.
import 'package:flutter/material.dart';

/// Signature for the reorder callback.
typedef ReorderItemCallback = void Function(int oldIndex, int newIndex);

/// A responsive tile grid with reorder support.
///
/// Layout:
/// - Narrow (< [breakpoint]): [narrowColumns] columns (default 2 for phones)
/// - Wide   (>= [breakpoint]): [wideColumns] columns (default 4 for tablets)
///
/// Reordering: long-press a tile to enter pick mode, then tap the
/// destination slot to complete the move. The [onReorderItem] callback
/// fires with (oldIndex, newIndex) when the move is confirmed.
class ReorderableTileGrid extends StatefulWidget {
  const ReorderableTileGrid({
    super.key,
    required this.children,
    required this.onReorderItem,
    this.spacing = 12,
    this.runSpacing = 12,
    this.narrowColumns = 2,
    this.wideColumns = 4,
    this.breakpoint = 600,
    this.padding,
  });

  final List<Widget> children;
  final ReorderItemCallback onReorderItem;
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
  /// Index of the tile being moved, or -1 when idle.
  int _pickIndex = -1;

  @override
  Widget build(BuildContext context) {
    final children = widget.children;
    if (children.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final columns = width >= widget.breakpoint
          ? widget.wideColumns
          : widget.narrowColumns;
      final tileWidth = (width -
              widget.spacing * (columns - 1) -
              (widget.padding?.horizontal ?? 0)) /
          columns;
      final bool picking = _pickIndex >= 0;

      return Padding(
        padding: widget.padding ?? EdgeInsets.zero,
        child: Wrap(
          spacing: widget.spacing,
          runSpacing: widget.runSpacing,
          children: List.generate(children.length, (i) {
            final isPicked = i == _pickIndex;
            // When picking, show a subtle ring on the picked tile.
            return SizedBox(
              width: tileWidth,
              child: Container(
                decoration: isPicked
                    ? BoxDecoration(
                        shape: BoxShape.rectangle,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: cs.primary, width: 2.5),
                      )
                    : null,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  // Cancel pick mode by tapping the picked tile.
                  onTap: isPicked
                      ? () => setState(() => _pickIndex = -1)
                      : (picking ? () => _drop(i) : null),
                  child: children[i],
                ),
              ),
            );
          }),
        ),
      );
    });
  }

  void _drop(int targetIndex) {
    final oldIdx = _pickIndex;
    setState(() => _pickIndex = -1);
    if (oldIdx >= 0 && oldIdx != targetIndex) {
      widget.onReorderItem(oldIdx, targetIndex);
    }
  }
}