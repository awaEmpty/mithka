import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chats/search_view.dart';
import 'package:mithka/tdlib/td_models.dart';

void main() {
  ChatMessage photo() => ChatMessage(
    id: 1,
    isOutgoing: false,
    text: '',
    date: 1,
    contentType: 'messagePhoto',
    image: TdFileRef(id: 11),
  );

  ChatMessage music() => ChatMessage(
    id: 2,
    isOutgoing: false,
    text: '',
    date: 2,
    contentType: 'messageAudio',
    music: MessageMusic(title: 'Song', cover: TdFileRef(id: 22)),
  );

  test('the Messages tab shows the sender avatar even for a photo', () {
    expect(searchTabMediaThumb(photo(), SearchTab.posts), isNull);
    expect(searchTabMediaThumb(music(), SearchTab.posts), isNull);
  });

  test('only the Media tab uses the message thumbnail', () {
    expect(searchTabMediaThumb(photo(), SearchTab.media)?.id, 11);
  });

  test('only the Music tab uses the track cover', () {
    expect(searchTabMediaThumb(music(), SearchTab.music)?.id, 22);
    expect(searchTabMediaThumb(music(), SearchTab.files), isNull);
  });
}
