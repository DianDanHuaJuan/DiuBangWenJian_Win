import 'package:diubangwenjian/core/http/content_disposition.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('inline streaming has no filename', () {
    expect(ContentDisposition.inline, 'inline');
    expect(ContentDisposition.inline.contains('filename'), isFalse);
  });

  test('attachment uses only filename* (ASCII header)', () {
    final h = ContentDisposition.attachment('暴力熊视频.mp4');
    expect(h, startsWith('attachment;'));
    expect(h, contains("filename*=UTF-8''"));
    expect(h, contains(Uri.encodeComponent('暴力熊视频.mp4')));
    expect(h.contains('filename="'), isFalse);
    expect(RegExp(r'[\u0080-\uFFFF]').hasMatch(h), isFalse);
  });

  test('attachment strips path and handles empty', () {
    expect(
      ContentDisposition.attachment(r'F:\dir\clip.mp4'),
      "attachment; filename*=UTF-8''clip.mp4",
    );
    expect(
      ContentDisposition.attachment('   '),
      "attachment; filename*=UTF-8''download",
    );
  });
}
