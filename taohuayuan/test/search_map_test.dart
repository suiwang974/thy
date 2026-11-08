import 'package:flutter_test/flutter_test.dart';
import 'package:taohuayuan/data/search_map.dart';

void main() {
  test('足 -> foot', () {
    expect(mapSearchQuery('足'), 'foot');
  });

  test('足交 -> footjob（长词优先，不能被“足”截走）', () {
    expect(mapSearchQuery('足交'), 'footjob');
    expect(mapSearchQuery('足控'), 'footjob');
  });

  test('八重神子 -> yae miko', () {
    expect(mapSearchQuery('八重神子'), 'yae miko');
  });

  test('混合词：中文映射 + 英文原样保留', () {
    expect(mapSearchQuery('足 八重神子'), 'foot yae miko');
    expect(mapSearchQuery('footjob'), 'footjob');
  });

  test('空输入原样返回', () {
    expect(mapSearchQuery('  '), '');
  });
}
