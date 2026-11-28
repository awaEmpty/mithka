//
//  instant_view_models.dart
//
//  Typed model of TDLib's `webPageInstantView` page blocks. TDLib hands the
//  article over as a tree of `pageBlock*` objects with `RichText` runs; this
//  file turns that JSON into the value types the Instant View renderer walks.
//  Parsing never throws: an unknown block or run degrades to text or to
//  `IvUnsupportedBlock`, so a future TDLib can add block kinds without
//  blanking the article.
//

import 'dart:typed_data';

import '../../tdlib/json_helpers.dart';
import '../../tdlib/td_models.dart';

/// One Instant View article, as returned by `getWebPageInstantView`.
class InstantViewPage {
  const InstantViewPage({
    required this.blocks,
    this.viewCount = 0,
    this.version = 0,
    this.isRtl = false,
    this.isFull = false,
  });

  final List<IvBlock> blocks;
  final int viewCount;
  final int version;
  final bool isRtl;

  /// True when Telegram served the complete page; false for a partial page
  /// that needs the canonical web page for the rest.
  final bool isFull;

  bool get isEmpty => blocks.isEmpty;

  static InstantViewPage parse(Map<String, dynamic> json) {
    return InstantViewPage(
      blocks: [
        for (final block in json.objects('blocks') ?? const <TdObject>[])
          parseIvBlock(block),
      ],
      viewCount: json.integer('view_count') ?? 0,
      version: json.integer('version') ?? 0,
      isRtl: json.boolean('is_rtl') ?? false,
      isFull: json.boolean('is_full') ?? false,
    );
  }
}

// ---------------------------------------------------------------------------
// Rich text
// ---------------------------------------------------------------------------

sealed class IvText {
  const IvText();
}

class IvTextPlain extends IvText {
  const IvTextPlain(this.text);
  final String text;
}

class IvTextConcat extends IvText {
  const IvTextConcat(this.children);
  final List<IvText> children;
}

enum IvTextStyle {
  bold,
  italic,
  underline,
  strikethrough,
  spoiler,
  subscript,
  superscript,
  marked,
  fixed,
}

class IvTextStyled extends IvText {
  const IvTextStyled(this.style, this.child);
  final IvTextStyle style;
  final IvText child;
}

enum IvLinkKind {
  url,
  email,
  phone,
  mention,
  hashtag,
  cashtag,
  botCommand,
  bankCard,
  tonAddress,
  mentionName,
  anchor,
  anchorLink,
  referenceLink,
}

class IvTextLink extends IvText {
  const IvTextLink({
    required this.kind,
    required this.value,
    required this.child,
    this.fallbackUrl = '',
    this.userId,
    this.isCached = false,
  });

  final IvLinkKind kind;

  /// URL, e-mail address, phone number, username, anchor name or reference
  /// name, depending on [kind].
  final String value;

  /// For `richTextAnchorLink`: the web URL to use when the article has no
  /// matching anchor.
  final String fallbackUrl;
  final int? userId;
  final bool isCached;
  final IvText child;
}

class IvTextCustomEmoji extends IvText {
  const IvTextCustomEmoji({required this.id, required this.alternativeText});
  final int id;
  final String alternativeText;
}

class IvTextIcon extends IvText {
  const IvTextIcon({this.file, required this.width, required this.height});
  final TdFileRef? file;
  final int width;
  final int height;
}

class IvTextMath extends IvText {
  const IvTextMath(this.expression);
  final String expression;
}

class IvTextDate extends IvText {
  const IvTextDate({required this.child, required this.unixTime});
  final IvText child;
  final int unixTime;
}

class IvTextButton extends IvText {
  const IvTextButton(this.button);
  final IvButton button;
}

class IvTextDiff extends IvText {
  const IvTextDiff({required this.text, required this.oldText});
  final IvText text;
  final IvText oldText;
}

class IvTextReference extends IvText {
  const IvTextReference({required this.name, required this.text});
  final String name;
  final IvText text;
}

class IvTextAnchor extends IvText {
  const IvTextAnchor(this.name);
  final String name;
}

class IvTextUnknown extends IvText {
  const IvTextUnknown(this.text);
  final String text;
}

/// Parses one `RichText` object. Null and unknown shapes become empty text.
IvText parseIvText(Object? raw) {
  if (raw is! Map<String, dynamic>) return const IvTextPlain('');
  switch (raw.type) {
    case 'richTextPlain':
      return IvTextPlain(raw.str('text') ?? '');
    case 'richTexts':
      return IvTextConcat([
        for (final child in raw.objects('texts') ?? const <TdObject>[])
          parseIvText(child),
      ]);
    case 'richTextBold':
      return IvTextStyled(IvTextStyle.bold, parseIvText(raw['text']));
    case 'richTextItalic':
      return IvTextStyled(IvTextStyle.italic, parseIvText(raw['text']));
    case 'richTextUnderline':
      return IvTextStyled(IvTextStyle.underline, parseIvText(raw['text']));
    case 'richTextStrikethrough':
      return IvTextStyled(IvTextStyle.strikethrough, parseIvText(raw['text']));
    case 'richTextSpoiler':
      return IvTextStyled(IvTextStyle.spoiler, parseIvText(raw['text']));
    case 'richTextSubscript':
      return IvTextStyled(IvTextStyle.subscript, parseIvText(raw['text']));
    case 'richTextSuperscript':
      return IvTextStyled(IvTextStyle.superscript, parseIvText(raw['text']));
    case 'richTextMarked':
      return IvTextStyled(IvTextStyle.marked, parseIvText(raw['text']));
    case 'richTextFixed':
      return IvTextStyled(IvTextStyle.fixed, parseIvText(raw['text']));
    case 'richTextUrl':
      return IvTextLink(
        kind: IvLinkKind.url,
        value: raw.str('url') ?? '',
        isCached: raw.boolean('is_cached') ?? false,
        child: parseIvText(raw['text']),
      );
    case 'richTextEmailAddress':
      return IvTextLink(
        kind: IvLinkKind.email,
        value: raw.str('email_address') ?? '',
        child: parseIvText(raw['text']),
      );
    case 'richTextPhoneNumber':
      return IvTextLink(
        kind: IvLinkKind.phone,
        value: raw.str('phone_number') ?? '',
        child: parseIvText(raw['text']),
      );
    case 'richTextMention':
      return IvTextLink(
        kind: IvLinkKind.mention,
        value: raw.str('username') ?? '',
        child: parseIvText(raw['text']),
      );
    case 'richTextHashtag':
      return IvTextLink(
        kind: IvLinkKind.hashtag,
        value: raw.str('hashtag') ?? '',
        child: parseIvText(raw['text']),
      );
    case 'richTextCashtag':
      return IvTextLink(
        kind: IvLinkKind.cashtag,
        value: raw.str('cashtag') ?? '',
        child: parseIvText(raw['text']),
      );
    case 'richTextBotCommand':
      return IvTextLink(
        kind: IvLinkKind.botCommand,
        value: raw.str('bot_command') ?? '',
        child: parseIvText(raw['text']),
      );
    case 'richTextBankCardNumber':
      return IvTextLink(
        kind: IvLinkKind.bankCard,
        value: raw.str('bank_card_number') ?? '',
        child: parseIvText(raw['text']),
      );
    case 'richTextTonAddress':
      return IvTextLink(
        kind: IvLinkKind.tonAddress,
        value: raw.str('address') ?? '',
        child: parseIvText(raw['text']),
      );
    case 'richTextMentionName':
      return IvTextLink(
        kind: IvLinkKind.mentionName,
        value: '',
        userId: raw.int64('user_id'),
        child: parseIvText(raw['text']),
      );
    case 'richTextAnchor':
      return IvTextAnchor(raw.str('name') ?? '');
    case 'richTextAnchorLink':
      return IvTextLink(
        kind: IvLinkKind.anchorLink,
        value: raw.str('anchor_name') ?? '',
        fallbackUrl: raw.str('url') ?? '',
        child: parseIvText(raw['text']),
      );
    case 'richTextReference':
      return IvTextReference(
        name: raw.str('name') ?? '',
        text: parseIvText(raw['text']),
      );
    case 'richTextReferenceLink':
      return IvTextLink(
        kind: IvLinkKind.referenceLink,
        value: raw.str('reference_name') ?? '',
        fallbackUrl: raw.str('url') ?? '',
        child: parseIvText(raw['text']),
      );
    case 'richTextCustomEmoji':
      return IvTextCustomEmoji(
        id: raw.int64('custom_emoji_id') ?? 0,
        alternativeText: raw.str('alternative_text') ?? '',
      );
    case 'richTextIcon':
      final document = raw.obj('document');
      return IvTextIcon(
        file: TDParse.fileRef(document?.obj('document')),
        width: raw.integer('width') ?? 0,
        height: raw.integer('height') ?? 0,
      );
    case 'richTextMathematicalExpression':
      return IvTextMath(raw.str('expression') ?? '');
    case 'richTextDateTime':
      return IvTextDate(
        child: parseIvText(raw['text']),
        unixTime: raw.integer('unix_time') ?? 0,
      );
    case 'richTextButton':
      return IvTextButton(parseIvButton(raw.obj('button')));
    case 'richTextDiff':
      return IvTextDiff(
        text: parseIvText(raw['text']),
        oldText: parseIvText(raw['old_text']),
      );
    default:
      // A future inline run usually keeps a `text` child; walk it rather
      // than dropping the sentence it belongs to.
      final child = raw['text'];
      if (child is Map<String, dynamic>) return parseIvText(child);
      return const IvTextUnknown('');
  }
}

/// The flattened text of [text], used as a stable fallback for titles and
/// accessibility labels.
String ivTextToPlain(IvText text) {
  final buffer = StringBuffer();
  void walk(IvText node) {
    switch (node) {
      case IvTextPlain(:final text):
        buffer.write(text);
      case IvTextConcat(:final children):
        children.forEach(walk);
      case IvTextStyled(:final child):
        walk(child);
      case IvTextLink(:final child):
        walk(child);
      case IvTextCustomEmoji(:final alternativeText):
        buffer.write(alternativeText);
      case IvTextMath(:final expression):
        buffer.write(expression);
      case IvTextDate(:final child):
        walk(child);
      case IvTextButton(:final button):
        buffer.write(button.text);
      case IvTextDiff(:final text):
        walk(text);
      case IvTextReference(:final text):
        walk(text);
      case IvTextIcon():
      case IvTextAnchor():
      case IvTextUnknown():
        break;
    }
  }

  walk(text);
  return buffer.toString();
}

/// Flattened, searchable text of one block (nested containers included).
String ivBlockPlainText(IvBlock block) {
  final buffer = StringBuffer();
  void blockText(IvBlock node) {
    switch (node) {
      case IvTitleBlock(:final title):
        buffer.write(ivTextToPlain(title));
      case IvSubtitleBlock(:final subtitle):
        buffer.write(ivTextToPlain(subtitle));
      case IvAuthorDateBlock(:final author):
        buffer.write(ivTextToPlain(author));
      case IvHeaderBlock(:final header):
        buffer.write(ivTextToPlain(header));
      case IvSubheaderBlock(:final subheader):
        buffer.write(ivTextToPlain(subheader));
      case IvSectionHeadingBlock(:final text):
        buffer.write(ivTextToPlain(text));
      case IvKickerBlock(:final text):
        buffer.write(ivTextToPlain(text));
      case IvParagraphBlock(:final text):
        buffer.write(ivTextToPlain(text));
      case IvPreformattedBlock(:final text):
        buffer.write(ivTextToPlain(text));
      case IvFooterBlock(:final text):
        buffer.write(ivTextToPlain(text));
      case IvThinkingBlock(:final text):
        buffer.write(ivTextToPlain(text));
      case IvMathBlock(:final expression):
        buffer.write(expression);
      case IvListBlock(:final items):
        for (final item in items) {
          for (final child in item.blocks) {
            blockText(child);
          }
        }
      case IvBlockQuoteBlock(:final blocks, :final credit):
        blocks.forEach(blockText);
        buffer.write(ivTextToPlain(credit));
      case IvExpandableQuoteBlock(:final text, :final blocks, :final credit):
        buffer.write(ivTextToPlain(text));
        blocks.forEach(blockText);
        buffer.write(ivTextToPlain(credit));
      case IvPullQuoteBlock(:final text, :final credit):
        buffer.write(ivTextToPlain(text));
        buffer.write(ivTextToPlain(credit));
      case IvCoverBlock(:final cover):
        blockText(cover);
      case IvEmbeddedBlock(:final caption):
        buffer.write(ivTextToPlain(caption.text));
      case IvEmbeddedPostBlock(:final author, :final blocks, :final caption):
        buffer.write(author);
        blocks.forEach(blockText);
        buffer.write(ivTextToPlain(caption.text));
      case IvCollageBlock(:final caption) || IvSlideshowBlock(:final caption):
        buffer.write(ivTextToPlain(caption.text));
      case IvChatLinkBlock(:final title, :final username):
        buffer
          ..write(title)
          ..write(username);
      case IvTableBlock(:final caption, :final cells):
        buffer.write(ivTextToPlain(caption));
        for (final row in cells) {
          for (final cell in row) {
            buffer.write(ivTextToPlain(cell.text));
          }
        }
      case IvDetailsBlock(:final header, :final blocks):
        buffer.write(ivTextToPlain(header));
        blocks.forEach(blockText);
      case IvRelatedArticlesBlock(:final header, :final articles):
        buffer.write(ivTextToPlain(header));
        for (final article in articles) {
          buffer
            ..write(article.title)
            ..write(article.description)
            ..write(article.author);
        }
      case IvMapBlock():
      case IvDividerBlock():
      case IvAnchorBlock():
      case IvButtonRowBlock():
      case IvPhotoBlock():
      case IvVideoBlock():
      case IvAnimationBlock():
      case IvAudioBlock():
      case IvVoiceNoteBlock():
      case IvDocumentBlock():
      case IvUnsupportedBlock():
        break;
    }
  }

  blockText(block);
  return buffer.toString();
}

// ---------------------------------------------------------------------------
// Captions, buttons and shared leaves
// ---------------------------------------------------------------------------

class IvCaption {
  const IvCaption({
    this.text = const IvTextPlain(''),
    this.credit = const IvTextPlain(''),
  });
  final IvText text;
  final IvText credit;

  bool get isEmpty =>
      ivTextToPlain(text).trim().isEmpty &&
      ivTextToPlain(credit).trim().isEmpty;

  static IvCaption parse(Map<String, dynamic>? json) {
    if (json == null) return const IvCaption();
    return IvCaption(
      text: parseIvText(json['text']),
      credit: parseIvText(json['credit']),
    );
  }
}

class IvButton {
  const IvButton({required this.text, this.url});
  final String text;

  /// Null for callback/switch buttons, which have no meaning outside a chat.
  final String? url;

  bool get isActionable => url != null && url!.isNotEmpty;
}

IvButton parseIvButton(Map<String, dynamic>? json) {
  final text = json?.str('text') ?? '';
  final type = json?.obj('type');
  final url = type?.type == 'inlineKeyboardButtonTypeUrl'
      ? (type?.str('url') ?? '')
      : null;
  return IvButton(text: text, url: url);
}

class IvRelatedArticle {
  const IvRelatedArticle({
    required this.url,
    this.title = '',
    this.description = '',
    this.photo,
    this.author = '',
    this.publishDate = 0,
  });

  final String url;
  final String title;
  final String description;
  final MediaAttachment? photo;
  final String author;
  final int publishDate;

  static IvRelatedArticle parse(Map<String, dynamic> json) {
    final photo = json.obj('photo');
    final attachment = photo == null ? null : TDParse.photoAttachment(photo);
    return IvRelatedArticle(
      url: json.str('url') ?? '',
      title: json.str('title') ?? '',
      description: json.str('description') ?? '',
      photo: attachment?.image == null ? null : attachment,
      author: json.str('author') ?? '',
      publishDate: json.integer('publish_date') ?? 0,
    );
  }
}

class IvListItem {
  const IvListItem({
    required this.label,
    required this.blocks,
    this.hasCheckbox = false,
    this.isChecked = false,
    this.value = 0,
    this.type = '',
  });

  final String label;
  final List<IvBlock> blocks;
  final bool hasCheckbox;
  final bool isChecked;
  final int value;
  final String type;

  static IvListItem parse(Map<String, dynamic> json) {
    return IvListItem(
      label: json.str('label') ?? '',
      blocks: [
        for (final block in json.objects('blocks') ?? const <TdObject>[])
          parseIvBlock(block),
      ],
      hasCheckbox: json.boolean('has_checkbox') ?? false,
      isChecked: json.boolean('is_checked') ?? false,
      value: json.integer('value') ?? 0,
      type: json.str('type') ?? '',
    );
  }
}

enum IvAlign { left, center, right }

enum IvVAlign { top, middle, bottom }

class IvTableCell {
  const IvTableCell({
    required this.text,
    this.isHeader = false,
    this.colspan = 1,
    this.rowspan = 1,
    this.align = IvAlign.left,
    this.valign = IvVAlign.top,
  });

  final IvText text;
  final bool isHeader;
  final int colspan;
  final int rowspan;
  final IvAlign align;
  final IvVAlign valign;

  static IvTableCell parse(Map<String, dynamic> json) {
    final align = switch (json.obj('align')?.type) {
      'pageBlockHorizontalAlignmentCenter' => IvAlign.center,
      'pageBlockHorizontalAlignmentRight' => IvAlign.right,
      _ => IvAlign.left,
    };
    final valign = switch (json.obj('valign')?.type) {
      'pageBlockVerticalAlignmentMiddle' => IvVAlign.middle,
      'pageBlockVerticalAlignmentBottom' => IvVAlign.bottom,
      _ => IvVAlign.top,
    };
    return IvTableCell(
      text: parseIvText(json['text']),
      isHeader: json.boolean('is_header') ?? false,
      colspan: (json.integer('colspan') ?? 1).clamp(1, 1000),
      rowspan: (json.integer('rowspan') ?? 1).clamp(1, 1000),
      align: align,
      valign: valign,
    );
  }
}

// ---------------------------------------------------------------------------
// Media leaves
// ---------------------------------------------------------------------------

class IvPhoto {
  const IvPhoto({
    required this.media,
    this.miniThumb,
    this.url,
    this.width,
    this.height,
  });

  final MediaAttachment media;
  final Uint8List? miniThumb;

  /// Remote image extracted from a web page by the local Instant View; when
  /// set, [media] carries no TDLib file and the renderer loads this URL.
  final String? url;
  final int? width;
  final int? height;

  bool get isEmpty =>
      media.image == null &&
      miniThumb == null &&
      (url == null || url!.trim().isEmpty);
}

class IvVideo {
  const IvVideo({required this.media, this.duration = 0, this.loop = false});
  final MediaAttachment media;
  final int duration;
  final bool loop;

  bool get isEmpty => media.image == null && media.video == null;
}

class IvAudio {
  const IvAudio({
    required this.file,
    this.cover,
    this.title = '',
    this.performer = '',
    this.fileName = '',
    this.duration = 0,
  });

  final TdFileRef? file;
  final TdFileRef? cover;
  final String title;
  final String performer;
  final String fileName;
  final int duration;

  /// Empty when the file carries no name; the renderer supplies its own
  /// localized fallback.
  String get displayTitle {
    if (title.trim().isNotEmpty) return title.trim();
    return fileName.trim();
  }
}

class IvVoiceNote {
  const IvVoiceNote({
    required this.file,
    this.duration = 0,
    this.waveform = '',
  });
  final TdFileRef? file;
  final int duration;
  final String waveform;
}

class IvDocument {
  const IvDocument({
    required this.file,
    this.fileName = '',
    this.mimeType = '',
  });

  final TdFileRef? file;
  final String fileName;
  final String mimeType;
}

IvPhoto? parseIvPhoto(Map<String, dynamic>? photo) {
  if (photo == null) return null;
  final media = TDParse.photoAttachment(photo);
  final mini = TDParse.decodeMiniThumb(photo.obj('minithumbnail'));
  if (media.image == null && mini == null) return null;
  return IvPhoto(media: media, miniThumb: mini);
}

IvVideo? parseIvVideo(Map<String, dynamic>? video, {bool loop = false}) {
  if (video == null) return null;
  final media = TDParse.videoAttachment(video);
  if (media.image == null && media.video == null) return null;
  return IvVideo(
    media: media,
    duration: video.integer('duration') ?? 0,
    loop: loop,
  );
}

/// `pageBlockAnimation.animation` is an `animation` object, whose playable
/// file lives under `animation`, not `video`.
IvVideo? parseIvAnimation(Map<String, dynamic>? animation) {
  if (animation == null) return null;
  final media = TDParse.animationAttachment(animation);
  if (media.image == null && media.video == null) return null;
  return IvVideo(
    media: media,
    duration: animation.integer('duration') ?? 0,
    loop: true,
  );
}

/// `pageBlockChatLink.photo` is a `chatPhotoInfo` (direct `small`/`big` file
/// references), not a `photo` with sizes.
IvPhoto? parseIvChatPhoto(Map<String, dynamic>? photo) {
  if (photo == null) return null;
  final mini = TDParse.decodeMiniThumb(photo.obj('minithumbnail'));
  final file =
      TDParse.fileRef(photo.obj('big'), miniThumb: mini) ??
      TDParse.fileRef(photo.obj('small'), miniThumb: mini);
  if (file == null) return null;
  return IvPhoto(
    media: MediaAttachment(image: file),
    miniThumb: mini,
  );
}

IvAudio parseIvAudio(Map<String, dynamic>? audio) {
  final mini = TDParse.decodeMiniThumb(audio?.obj('album_cover_minithumbnail'));
  return IvAudio(
    file: TDParse.fileRef(audio?.obj('audio')),
    cover: TDParse.fileRef(
      audio?.obj('album_cover_thumbnail')?.obj('file'),
      miniThumb: mini,
    ),
    title: audio?.str('title') ?? '',
    performer: audio?.str('performer') ?? '',
    fileName: audio?.str('file_name') ?? '',
    duration: audio?.integer('duration') ?? 0,
  );
}

IvVoiceNote parseIvVoiceNote(Map<String, dynamic>? note) => IvVoiceNote(
  file: TDParse.fileRef(note?.obj('voice')),
  duration: note?.integer('duration') ?? 0,
  waveform: note?.str('waveform') ?? '',
);

IvDocument parseIvDocument(Map<String, dynamic>? document) => IvDocument(
  file: TDParse.fileRef(document?.obj('document')),
  fileName: document?.str('file_name') ?? '',
  mimeType: document?.str('mime_type') ?? '',
);

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

sealed class IvBlock {
  const IvBlock();
}

class IvTitleBlock extends IvBlock {
  const IvTitleBlock(this.title);
  final IvText title;
}

class IvSubtitleBlock extends IvBlock {
  const IvSubtitleBlock(this.subtitle);
  final IvText subtitle;
}

class IvAuthorDateBlock extends IvBlock {
  const IvAuthorDateBlock({required this.author, this.publishDate = 0});
  final IvText author;
  final int publishDate;
}

class IvHeaderBlock extends IvBlock {
  const IvHeaderBlock(this.header);
  final IvText header;
}

class IvSubheaderBlock extends IvBlock {
  const IvSubheaderBlock(this.subheader);
  final IvText subheader;
}

class IvSectionHeadingBlock extends IvBlock {
  const IvSectionHeadingBlock({required this.text, this.size = 1});
  final IvText text;
  final int size;
}

class IvKickerBlock extends IvBlock {
  const IvKickerBlock(this.text);
  final IvText text;
}

class IvParagraphBlock extends IvBlock {
  const IvParagraphBlock(this.text);
  final IvText text;
}

class IvPreformattedBlock extends IvBlock {
  const IvPreformattedBlock({required this.text, this.language = ''});
  final IvText text;
  final String language;
}

class IvFooterBlock extends IvBlock {
  const IvFooterBlock(this.text);
  final IvText text;
}

class IvThinkingBlock extends IvBlock {
  const IvThinkingBlock(this.text);
  final IvText text;
}

class IvDividerBlock extends IvBlock {
  const IvDividerBlock();
}

class IvMathBlock extends IvBlock {
  const IvMathBlock(this.expression);
  final String expression;
}

class IvAnchorBlock extends IvBlock {
  const IvAnchorBlock(this.name);
  final String name;
}

class IvListBlock extends IvBlock {
  const IvListBlock(this.items);
  final List<IvListItem> items;
}

class IvBlockQuoteBlock extends IvBlock {
  const IvBlockQuoteBlock({
    required this.blocks,
    this.credit = const IvTextPlain(''),
  });
  final List<IvBlock> blocks;
  final IvText credit;
}

class IvExpandableQuoteBlock extends IvBlock {
  const IvExpandableQuoteBlock({
    this.text = const IvTextPlain(''),
    this.blocks = const [],
    this.credit = const IvTextPlain(''),
  });
  final IvText text;
  final List<IvBlock> blocks;
  final IvText credit;

  bool get hasBlocks => blocks.isNotEmpty;
}

class IvPullQuoteBlock extends IvBlock {
  const IvPullQuoteBlock({
    this.text = const IvTextPlain(''),
    this.credit = const IvTextPlain(''),
  });
  final IvText text;
  final IvText credit;
}

class IvAnimationBlock extends IvBlock {
  const IvAnimationBlock({
    required this.animation,
    this.caption = const IvCaption(),
    this.needAutoplay = false,
    this.hasSpoiler = false,
  });
  final IvVideo animation;
  final IvCaption caption;
  final bool needAutoplay;
  final bool hasSpoiler;
}

class IvAudioBlock extends IvBlock {
  const IvAudioBlock({required this.audio, this.caption = const IvCaption()});
  final IvAudio audio;
  final IvCaption caption;
}

class IvDocumentBlock extends IvBlock {
  const IvDocumentBlock({
    required this.document,
    this.caption = const IvCaption(),
  });
  final IvDocument document;
  final IvCaption caption;
}

class IvPhotoBlock extends IvBlock {
  const IvPhotoBlock({
    required this.photo,
    this.caption = const IvCaption(),
    this.url = '',
    this.hasSpoiler = false,
  });
  final IvPhoto photo;
  final IvCaption caption;
  final String url;
  final bool hasSpoiler;
}

class IvVideoBlock extends IvBlock {
  const IvVideoBlock({
    required this.video,
    this.caption = const IvCaption(),
    this.needAutoplay = false,
    this.hasSpoiler = false,
  });
  final IvVideo video;
  final IvCaption caption;
  final bool needAutoplay;
  final bool hasSpoiler;
}

class IvVoiceNoteBlock extends IvBlock {
  const IvVoiceNoteBlock({
    required this.voiceNote,
    this.caption = const IvCaption(),
  });
  final IvVoiceNote voiceNote;
  final IvCaption caption;
}

class IvCoverBlock extends IvBlock {
  const IvCoverBlock(this.cover);
  final IvBlock cover;
}

class IvEmbeddedBlock extends IvBlock {
  const IvEmbeddedBlock({
    this.url = '',
    this.html = '',
    this.poster,
    this.width = 0,
    this.height = 0,
    this.caption = const IvCaption(),
    this.isFullWidth = false,
    this.allowScrolling = false,
  });
  final String url;
  final String html;
  final IvPhoto? poster;
  final int width;
  final int height;
  final IvCaption caption;
  final bool isFullWidth;
  final bool allowScrolling;
}

class IvEmbeddedPostBlock extends IvBlock {
  const IvEmbeddedPostBlock({
    this.url = '',
    this.author = '',
    this.authorPhoto,
    this.date = 0,
    this.blocks = const [],
    this.caption = const IvCaption(),
  });
  final String url;
  final String author;
  final IvPhoto? authorPhoto;
  final int date;
  final List<IvBlock> blocks;
  final IvCaption caption;
}

class IvCollageBlock extends IvBlock {
  const IvCollageBlock({
    required this.blocks,
    this.caption = const IvCaption(),
  });
  final List<IvBlock> blocks;
  final IvCaption caption;
}

class IvSlideshowBlock extends IvBlock {
  const IvSlideshowBlock({
    required this.blocks,
    this.caption = const IvCaption(),
  });
  final List<IvBlock> blocks;
  final IvCaption caption;
}

class IvChatLinkBlock extends IvBlock {
  const IvChatLinkBlock({this.title = '', this.photo, this.username = ''});
  final String title;
  final IvPhoto? photo;
  final String username;
}

class IvTableBlock extends IvBlock {
  const IvTableBlock({
    this.caption = const IvTextPlain(''),
    required this.cells,
    this.isBordered = false,
    this.isStriped = false,
    this.isCompact = false,
  });
  final IvText caption;
  final List<List<IvTableCell>> cells;
  final bool isBordered;
  final bool isStriped;
  final bool isCompact;
}

class IvDetailsBlock extends IvBlock {
  const IvDetailsBlock({
    required this.header,
    required this.blocks,
    this.isOpen = false,
  });
  final IvText header;
  final List<IvBlock> blocks;
  final bool isOpen;
}

class IvRelatedArticlesBlock extends IvBlock {
  const IvRelatedArticlesBlock({required this.header, required this.articles});
  final IvText header;
  final List<IvRelatedArticle> articles;
}

class IvMapBlock extends IvBlock {
  const IvMapBlock({
    required this.latitude,
    required this.longitude,
    this.zoom = 0,
    this.width = 0,
    this.height = 0,
    this.caption = const IvCaption(),
  });
  final double latitude;
  final double longitude;
  final int zoom;
  final int width;
  final int height;
  final IvCaption caption;
}

class IvButtonRowBlock extends IvBlock {
  const IvButtonRowBlock({required this.buttons, this.align = IvAlign.left});
  final List<IvButton> buttons;
  final IvAlign align;
}

class IvUnsupportedBlock extends IvBlock {
  const IvUnsupportedBlock();
}

IvBlock parseIvBlock(Map<String, dynamic> json) {
  switch (json.type) {
    case 'pageBlockTitle':
      return IvTitleBlock(parseIvText(json['title']));
    case 'pageBlockSubtitle':
      return IvSubtitleBlock(parseIvText(json['subtitle']));
    case 'pageBlockAuthorDate':
      return IvAuthorDateBlock(
        author: parseIvText(json['author']),
        publishDate: json.integer('publish_date') ?? 0,
      );
    case 'pageBlockHeader':
      return IvHeaderBlock(parseIvText(json['header']));
    case 'pageBlockSubheader':
      return IvSubheaderBlock(parseIvText(json['subheader']));
    case 'pageBlockSectionHeading':
      return IvSectionHeadingBlock(
        text: parseIvText(json['text']),
        size: json.integer('size') ?? 1,
      );
    case 'pageBlockKicker':
      return IvKickerBlock(parseIvText(json['kicker']));
    case 'pageBlockParagraph':
      return IvParagraphBlock(parseIvText(json['text']));
    case 'pageBlockPreformatted':
      return IvPreformattedBlock(
        text: parseIvText(json['text']),
        language: json.str('language') ?? '',
      );
    case 'pageBlockFooter':
      return IvFooterBlock(parseIvText(json['footer']));
    case 'pageBlockThinking':
      return IvThinkingBlock(parseIvText(json['text']));
    case 'pageBlockDivider':
      return const IvDividerBlock();
    case 'pageBlockMathematicalExpression':
      return IvMathBlock(json.str('expression') ?? '');
    case 'pageBlockAnchor':
      return IvAnchorBlock(json.str('name') ?? '');
    case 'pageBlockList':
      return IvListBlock([
        for (final item in json.objects('items') ?? const <TdObject>[])
          IvListItem.parse(item),
      ]);
    case 'pageBlockBlockQuote':
      return IvBlockQuoteBlock(
        blocks: [
          for (final block in json.objects('blocks') ?? const <TdObject>[])
            parseIvBlock(block),
        ],
        credit: parseIvText(json['credit']),
      );
    case 'pageBlockExpandableBlockQuote':
      return IvExpandableQuoteBlock(
        text: parseIvText(json['text']),
        blocks: [
          for (final block in json.objects('blocks') ?? const <TdObject>[])
            parseIvBlock(block),
        ],
        credit: parseIvText(json['credit']),
      );
    case 'pageBlockPullQuote':
      return IvPullQuoteBlock(
        text: parseIvText(json['text']),
        credit: parseIvText(json['credit']),
      );
    case 'pageBlockAnimation':
      final animation = parseIvAnimation(json.obj('animation'));
      if (animation == null) return const IvUnsupportedBlock();
      return IvAnimationBlock(
        animation: animation,
        caption: IvCaption.parse(json.obj('caption')),
        needAutoplay: json.boolean('need_autoplay') ?? false,
        hasSpoiler: json.boolean('has_spoiler') ?? false,
      );
    case 'pageBlockAudio':
      return IvAudioBlock(
        audio: parseIvAudio(json.obj('audio')),
        caption: IvCaption.parse(json.obj('caption')),
      );
    case 'pageBlockDocument':
      return IvDocumentBlock(
        document: parseIvDocument(json.obj('document')),
        caption: IvCaption.parse(json.obj('caption')),
      );
    case 'pageBlockPhoto':
      final photo = parseIvPhoto(json.obj('photo'));
      if (photo == null) return const IvUnsupportedBlock();
      return IvPhotoBlock(
        photo: photo,
        caption: IvCaption.parse(json.obj('caption')),
        url: json.str('url') ?? '',
        hasSpoiler: json.boolean('has_spoiler') ?? false,
      );
    case 'pageBlockVideo':
      final video = parseIvVideo(json.obj('video'));
      if (video == null) return const IvUnsupportedBlock();
      return IvVideoBlock(
        video: video,
        caption: IvCaption.parse(json.obj('caption')),
        needAutoplay: json.boolean('need_autoplay') ?? false,
        hasSpoiler: json.boolean('has_spoiler') ?? false,
      );
    case 'pageBlockVoiceNote':
      return IvVoiceNoteBlock(
        voiceNote: parseIvVoiceNote(json.obj('voice_note')),
        caption: IvCaption.parse(json.obj('caption')),
      );
    case 'pageBlockCover':
      final cover = json.obj('cover');
      return IvCoverBlock(
        cover == null ? const IvUnsupportedBlock() : parseIvBlock(cover),
      );
    case 'pageBlockEmbedded':
      return IvEmbeddedBlock(
        url: json.str('url') ?? '',
        html: json.str('html') ?? '',
        poster: parseIvPhoto(json.obj('poster_photo')),
        width: json.integer('width') ?? 0,
        height: json.integer('height') ?? 0,
        caption: IvCaption.parse(json.obj('caption')),
        isFullWidth: json.boolean('is_full_width') ?? false,
        allowScrolling: json.boolean('allow_scrolling') ?? false,
      );
    case 'pageBlockEmbeddedPost':
      return IvEmbeddedPostBlock(
        url: json.str('url') ?? '',
        author: json.str('author') ?? '',
        authorPhoto: parseIvPhoto(json.obj('author_photo')),
        date: json.integer('date') ?? 0,
        blocks: [
          for (final block in json.objects('blocks') ?? const <TdObject>[])
            parseIvBlock(block),
        ],
        caption: IvCaption.parse(json.obj('caption')),
      );
    case 'pageBlockCollage':
      return IvCollageBlock(
        blocks: [
          for (final block in json.objects('blocks') ?? const <TdObject>[])
            parseIvBlock(block),
        ],
        caption: IvCaption.parse(json.obj('caption')),
      );
    case 'pageBlockSlideshow':
      return IvSlideshowBlock(
        blocks: [
          for (final block in json.objects('blocks') ?? const <TdObject>[])
            parseIvBlock(block),
        ],
        caption: IvCaption.parse(json.obj('caption')),
      );
    case 'pageBlockChatLink':
      return IvChatLinkBlock(
        title: json.str('title') ?? '',
        photo: parseIvChatPhoto(json.obj('photo')),
        username: json.str('username') ?? '',
      );
    case 'pageBlockTable':
      final rawRows = json['cells'];
      return IvTableBlock(
        caption: parseIvText(json['caption']),
        cells: [
          if (rawRows is List)
            for (final row in rawRows)
              [
                if (row is List)
                  for (final cell in row.whereType<Map<String, dynamic>>())
                    IvTableCell.parse(cell),
              ],
        ],
        isBordered: json.boolean('is_bordered') ?? false,
        isStriped: json.boolean('is_striped') ?? false,
        isCompact: json.boolean('is_compact') ?? false,
      );
    case 'pageBlockDetails':
      return IvDetailsBlock(
        header: parseIvText(json['header']),
        blocks: [
          for (final block in json.objects('blocks') ?? const <TdObject>[])
            parseIvBlock(block),
        ],
        isOpen: json.boolean('is_open') ?? false,
      );
    case 'pageBlockRelatedArticles':
      return IvRelatedArticlesBlock(
        header: parseIvText(json['header']),
        articles: [
          for (final article in json.objects('articles') ?? const <TdObject>[])
            IvRelatedArticle.parse(article),
        ],
      );
    case 'pageBlockMap':
      final location = json.obj('location');
      if (location == null) return const IvUnsupportedBlock();
      return IvMapBlock(
        latitude: location.dbl('latitude') ?? 0,
        longitude: location.dbl('longitude') ?? 0,
        zoom: json.integer('zoom') ?? 0,
        width: json.integer('width') ?? 0,
        height: json.integer('height') ?? 0,
        caption: IvCaption.parse(json.obj('caption')),
      );
    case 'pageBlockButtonRow':
      final align = switch (json.obj('align')?.type) {
        'pageBlockHorizontalAlignmentCenter' => IvAlign.center,
        'pageBlockHorizontalAlignmentRight' => IvAlign.right,
        _ => IvAlign.left,
      };
      return IvButtonRowBlock(
        buttons: [
          for (final button in json.objects('buttons') ?? const <TdObject>[])
            parseIvButton(button),
        ],
        align: align,
      );
    default:
      return const IvUnsupportedBlock();
  }
}
