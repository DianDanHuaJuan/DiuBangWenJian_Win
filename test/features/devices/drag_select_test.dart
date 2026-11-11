import 'package:diubangwenjian/features/devices/presentation/drag_select.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('网格坐标落到对应序号，空隙按步长归入格子', () {
    final cell = gridCellExtent(
      width: 400,
      crossAxisCount: 4,
      paddingLeft: 24,
      paddingRight: 24,
      crossSpacing: 4,
    );
    expect(cell, closeTo(85, 0.01));
    final first = uniformIndex(
      contentX: 24,
      contentY: 0,
      width: 400,
      crossAxisCount: 4,
      paddingLeft: 24,
      paddingRight: 24,
      paddingTop: 0,
      crossSpacing: 4,
      mainSpacing: 4,
      cellWidth: cell,
      cellHeight: cell,
      itemCount: 10,
    );
    final nextRow = uniformIndex(
      contentX: 24 + cell + 4,
      contentY: cell + 4,
      width: 400,
      crossAxisCount: 4,
      paddingLeft: 24,
      paddingRight: 24,
      paddingTop: 0,
      crossSpacing: 4,
      mainSpacing: 4,
      cellWidth: cell,
      cellHeight: cell,
      itemCount: 10,
    );
    expect(first, 0);
    expect(nextRow, 5);
  });

  test('从起点向后选中，回退时离开范围的格子恢复', () {
    final range = RangeDragSelection()
      ..begin(index: 1, alreadySelected: false, selected: {'a'});
    final keys = ['a', 'b', 'c', 'd', null];
    expect(range.apply(3, keys), {'a', 'b', 'c', 'd'});
    expect(range.apply(1, keys), {'a', 'b'});
  });

  test('起点已选中时，划过的一段改为取消', () {
    final range = RangeDragSelection()
      ..begin(index: 0, alreadySelected: true, selected: {'a', 'b', 'c'});
    expect(range.apply(2, ['a', 'b', 'c']), <String>{});
  });
}