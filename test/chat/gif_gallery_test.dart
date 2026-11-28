import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_view.dart';
import 'package:mithka/tdlib/td_models.dart';

void main() {
  ChatMessage gif(int id, {bool spoiler = false}) => ChatMessage(
    id: id,
    isOutgoing: false,
    text: '',
    date: id,
    contentType: 'messageAnimation',
    image: TdFileRef(id: 100 + id),
    video: TdFileRef(id: 200 + id),
    hasSpoiler: spoiler,
  );

  test('the GIF gallery keeps only motion pages that may preview', () {
    final first = gif(1);
    final photo = ChatMessage(
      id: 2,
      isOutgoing: false,
      text: '',
      date: 2,
      contentType: 'messagePhoto',
      image: TdFileRef(id: 9),
    );
    final hidden = gif(3, spoiler: true);
    final target = gif(4);

    final gallery = animationGalleryFor([first, photo, hidden, target], target);
    expect(gallery.map((m) => m.id), [1, 4]);
    expect(gallery.every((m) => m.video != null && m.image != null), isTrue);
  });

  test('a target outside the transcript is appended to its own gallery', () {
    final first = gif(1);
    final target = gif(7);
    final gallery = animationGalleryFor([first], target);
    expect(gallery.map((m) => m.id), [1, 7]);
  });
}
