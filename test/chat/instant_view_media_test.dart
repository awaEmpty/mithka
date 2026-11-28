//
//  instant_view_media_test.dart
//
//  Every page-block kind TDLib's pinned schema (1.8.69) can put in an
//  Instant View must survive parsing: the article renders structured blocks,
//  never a blank page because one block's JSON shape drifted.
//

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/instant_view/instant_view_models.dart';

Map<String, dynamic> _plain(String text) => {
  '@type': 'richTextPlain',
  'text': text,
};

Map<String, dynamic> _file(int id) => {
  '@type': 'file',
  'id': id,
  'size': 10,
  'expected_size': 10,
  'local': {
    '@type': 'localFile',
    'path': '',
    'can_be_downloaded': true,
    'can_be_deleted': false,
    'is_downloading_active': false,
    'is_downloading_completed': false,
    'download_offset': 0,
    'downloaded_prefix_size': 0,
    'downloaded_size': 0,
  },
  'remote': {
    '@type': 'remoteFile',
    'id': 'remote-$id',
    'unique_id': 'unique-$id',
    'is_uploading_active': false,
    'is_uploading_completed': true,
    'uploaded_size': 10,
  },
};

Map<String, dynamic> _photo() => {
  '@type': 'photo',
  'has_sticker': false,
  'minithumbnail': null,
  'sizes': [
    {
      '@type': 'photoSize',
      'type': 'm',
      'width': 800,
      'height': 600,
      'photo': _file(1),
    },
  ],
};

Map<String, dynamic> _thumbnail() => {
  '@type': 'thumbnail',
  'format': {'@type': 'thumbnailFormatJpeg'},
  'width': 320,
  'height': 180,
  'file': _file(9),
};

Map<String, dynamic> _caption(String text) => {
  'text': _plain(text),
  'credit': _plain('Credit'),
};

Map<String, dynamic> _block(String type, [Map<String, dynamic>? fields]) => {
  '@type': type,
  ...?fields,
};

List<Map<String, dynamic>> _blocks() => [
  _block('pageBlockSubtitle', {'subtitle': _plain('A subtitle')}),
  _block('pageBlockHeader', {'header': _plain('A header')}),
  _block('pageBlockSubheader', {'subheader': _plain('A subheader')}),
  _block('pageBlockSectionHeading', {'text': _plain('Section'), 'size': 3}),
  _block('pageBlockPreformatted', {
    'text': _plain('final x = 1;'),
    'language': 'dart',
  }),
  _block('pageBlockFooter', {'footer': _plain('The end')}),
  _block('pageBlockThinking', {'text': _plain('Considering…')}),
  _block('pageBlockDivider'),
  _block('pageBlockMathematicalExpression', {'expression': 'E = mc^2'}),
  _block('pageBlockBlockQuote', {
    'blocks': [
      _block('pageBlockParagraph', {'text': _plain('Quoted')}),
    ],
    'credit': _plain('Source'),
  }),
  _block('pageBlockExpandableBlockQuote', {
    'text': _plain('Long quoted text'),
    'credit': _plain(''),
  }),
  _block('pageBlockPullQuote', {'text': _plain('Pull'), 'credit': _plain('')}),
  _block('pageBlockPhoto', {
    'photo': _photo(),
    'caption': _caption('A photo'),
    'url': 'https://example.com/photo',
    'has_spoiler': true,
  }),
  _block('pageBlockAnimation', {
    'animation': {
      '@type': 'animation',
      'duration': 3,
      'width': 320,
      'height': 240,
      'file_name': 'a.mp4',
      'mime_type': 'video/mp4',
      'minithumbnail': null,
      'thumbnail': _thumbnail(),
      'animation': _file(2),
    },
    'caption': _caption(''),
    'need_autoplay': true,
    'has_spoiler': false,
  }),
  _block('pageBlockVideo', {
    'video': {
      '@type': 'video',
      'duration': 12,
      'width': 640,
      'height': 360,
      'file_name': 'v.mp4',
      'mime_type': 'video/mp4',
      'has_stickers': false,
      'minithumbnail': null,
      'thumbnail': _thumbnail(),
      'video': _file(3),
    },
    'caption': _caption('A video'),
    'need_autoplay': false,
    'is_looped': false,
    'has_spoiler': false,
  }),
  _block('pageBlockAudio', {
    'audio': {
      '@type': 'audio',
      'duration': 95,
      'title': 'Track',
      'performer': 'Artist',
      'file_name': 'track.mp3',
      'mime_type': 'audio/mpeg',
      'album_cover_minithumbnail': null,
      'album_cover_thumbnail': null,
      'audio': _file(4),
    },
    'caption': _caption(''),
  }),
  _block('pageBlockVoiceNote', {
    'voice_note': {
      '@type': 'voiceNote',
      'duration': 7,
      'waveform': '',
      'minithumbnail': null,
      'voice': _file(5),
    },
    'caption': _caption(''),
  }),
  _block('pageBlockDocument', {
    'document': {
      '@type': 'document',
      'file_name': 'doc.pdf',
      'mime_type': 'application/pdf',
      'minithumbnail': null,
      'thumbnail': null,
      'document': _file(6),
    },
    'caption': _caption(''),
  }),
  _block('pageBlockCover', {
    'cover': _block('pageBlockPhoto', {
      'photo': _photo(),
      'caption': _caption(''),
      'url': '',
      'has_spoiler': false,
    }),
  }),
  _block('pageBlockEmbedded', {
    'url': 'https://twitter.com/x/status/1',
    'html': '<blockquote/>',
    'poster_photo': _photo(),
    'width': 500,
    'height': 400,
    'caption': _caption(''),
    'is_full_width': true,
    'allow_scrolling': false,
  }),
  _block('pageBlockEmbeddedPost', {
    'url': 'https://twitter.com/x/status/1',
    'author': 'Twitter user',
    'author_photo': _photo(),
    'date': 1700000000,
    'blocks': [
      _block('pageBlockParagraph', {'text': _plain('Tweet')}),
    ],
    'caption': _caption(''),
  }),
  _block('pageBlockCollage', {
    'blocks': [
      _block('pageBlockPhoto', {
        'photo': _photo(),
        'caption': _caption(''),
        'url': '',
        'has_spoiler': false,
      }),
      _block('pageBlockPhoto', {
        'photo': _photo(),
        'caption': _caption(''),
        'url': '',
        'has_spoiler': false,
      }),
    ],
    'caption': _caption('Two photos'),
  }),
  _block('pageBlockSlideshow', {
    'blocks': [
      _block('pageBlockPhoto', {
        'photo': _photo(),
        'caption': _caption(''),
        'url': '',
        'has_spoiler': false,
      }),
    ],
    'caption': _caption(''),
  }),
  _block('pageBlockChatLink', {
    'title': 'Channel',
    'photo': {
      '@type': 'chatPhotoInfo',
      'small': _file(7),
      'big': _file(7),
      'minithumbnail': null,
      'has_animation': false,
      'is_personal': false,
    },
    'accent_color_id': 3,
    'username': 'channel',
  }),
  _block('pageBlockMap', {
    'location': {
      '@type': 'location',
      'latitude': 55.75,
      'longitude': 37.61,
      'horizontal_accuracy': 0.0,
    },
    'zoom': 14,
    'width': 600,
    'height': 300,
    'caption': _caption(''),
  }),
  _block('pageBlockButtonRow', {
    'buttons': [
      {
        'text': 'Open',
        'type': {
          '@type': 'inlineKeyboardButtonTypeUrl',
          'url': 'https://example.com/open',
        },
      },
    ],
    'align': {'@type': 'pageBlockHorizontalAlignmentCenter'},
  }),
];

void main() {
  test('parses every page-block kind in the pinned TDLib schema', () {
    final page = InstantViewPage.parse({
      '@type': 'webPageInstantView',
      'blocks': _blocks(),
      'view_count': 1,
      'version': 2,
      'is_rtl': false,
      'is_full': true,
      'feedback_link': {'@type': 'internalLinkTypeNone'},
    });

    expect(page.blocks.length, _blocks().length);
    expect(page.blocks.whereType<IvUnsupportedBlock>(), isEmpty);
    expect(page.blocks[0], isA<IvSubtitleBlock>());
    expect(page.blocks[1], isA<IvHeaderBlock>());
    expect(page.blocks[2], isA<IvSubheaderBlock>());
    expect((page.blocks[3] as IvSectionHeadingBlock).size, 3);
    final pre = page.blocks[4] as IvPreformattedBlock;
    expect(pre.language, 'dart');
    expect(ivTextToPlain(pre.text), 'final x = 1;');
    expect(page.blocks[5], isA<IvFooterBlock>());
    expect(page.blocks[6], isA<IvThinkingBlock>());
    expect(page.blocks[7], isA<IvDividerBlock>());
    expect((page.blocks[8] as IvMathBlock).expression, 'E = mc^2');

    final quote = page.blocks[9] as IvBlockQuoteBlock;
    expect(quote.blocks.single, isA<IvParagraphBlock>());
    expect(ivTextToPlain(quote.credit), 'Source');
    expect(page.blocks[10], isA<IvExpandableQuoteBlock>());
    expect(page.blocks[11], isA<IvPullQuoteBlock>());

    final photo = page.blocks[12] as IvPhotoBlock;
    expect(photo.photo.media.image?.id, 1);
    expect(photo.photo.media.width, 800);
    expect(photo.url, 'https://example.com/photo');
    expect(photo.hasSpoiler, isTrue);
    expect(ivTextToPlain(photo.caption.text), 'A photo');

    final animation = page.blocks[13] as IvAnimationBlock;
    expect(animation.animation.media.video?.id, 2);
    expect(animation.animation.loop, isTrue);
    expect(animation.needAutoplay, isTrue);

    final video = page.blocks[14] as IvVideoBlock;
    expect(video.video.media.video?.id, 3);
    expect(video.video.duration, 12);

    final audio = page.blocks[15] as IvAudioBlock;
    expect(audio.audio.file?.id, 4);
    expect(audio.audio.title, 'Track');
    expect(audio.audio.performer, 'Artist');

    final voice = page.blocks[16] as IvVoiceNoteBlock;
    expect(voice.voiceNote.file?.id, 5);
    expect(voice.voiceNote.duration, 7);

    final document = page.blocks[17] as IvDocumentBlock;
    expect(document.document.file?.id, 6);
    expect(document.document.fileName, 'doc.pdf');

    final cover = page.blocks[18] as IvCoverBlock;
    expect(cover.cover, isA<IvPhotoBlock>());

    final embedded = page.blocks[19] as IvEmbeddedBlock;
    expect(embedded.url, 'https://twitter.com/x/status/1');
    expect(embedded.poster?.media.image?.id, 1);
    expect(embedded.isFullWidth, isTrue);

    final post = page.blocks[20] as IvEmbeddedPostBlock;
    expect(post.author, 'Twitter user');
    expect(post.date, 1700000000);
    expect(post.blocks.single, isA<IvParagraphBlock>());

    expect((page.blocks[21] as IvCollageBlock).blocks.length, 2);
    expect((page.blocks[22] as IvSlideshowBlock).blocks.length, 1);

    final chatLink = page.blocks[23] as IvChatLinkBlock;
    expect(chatLink.username, 'channel');
    expect(chatLink.photo?.media.image?.id, 7);

    final map = page.blocks[24] as IvMapBlock;
    expect(map.latitude, 55.75);
    expect(map.zoom, 14);

    final buttons = page.blocks[25] as IvButtonRowBlock;
    expect(buttons.buttons.single.url, 'https://example.com/open');
    expect(buttons.align, IvAlign.center);
  });
}
