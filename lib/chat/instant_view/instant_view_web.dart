//
//  instant_view_web.dart
//
//  exteraless turns a page Telegram has no Instant View template for into an
//  article locally: `WebInstantView` loads the page in a WebView, runs
//  Telegram's `instant.js` (Readability + DOMPurify) and rebuilds the result
//  as page blocks. This file does the second half — it maps that JSON to the
//  same [IvBlock] tree the TDLib-backed reader renders, so Wikipedia and any
//  other readable page opens with the article layout instead of a WebView.
//
//  The JSON shape (see `assets/instant_view/instant.js`):
//    { title, byline, excerpt, siteName, content: [ string | node ] }
//    node = { tag, content: [...], ...htmlAttributes, bold?, italic? }
//  Parsing never throws: an unknown tag is recursed into, and a node without
//  any renderable content is dropped.
//

import 'dart:convert';

import 'package:flutter/services.dart';

import '../../tdlib/td_models.dart';
import 'instant_view_models.dart';

/// Builds an [InstantViewPage] from `instant.js`'s JSON.
InstantViewPage parseWebInstantViewPage(
  Map<String, dynamic> json, {
  required String url,
}) {
  final blocks = <IvBlock>[];
  final title = (json['title'] as String?)?.trim() ?? '';
  if (title.isNotEmpty && title != 'null') {
    blocks.add(IvTitleBlock(IvTextPlain(title)));
  }
  final content = json['content'];
  if (content is List) {
    blocks.addAll(_webBlocks(content, url));
  }
  // The page may start with its own h1; the reader already shows the title.
  while (blocks.length > 1 &&
      blocks.first is IvTitleBlock &&
      blocks[1] is IvTitleBlock) {
    blocks.removeAt(1);
  }
  return InstantViewPage(blocks: blocks, version: 1, isFull: true);
}

List<IvBlock> _webBlocks(List<dynamic> nodes, String baseUrl) {
  final blocks = <IvBlock>[];
  for (final node in nodes) {
    if (node is String) {
      final text = node.trim();
      if (text.isNotEmpty) blocks.add(IvParagraphBlock(IvTextPlain(text)));
      continue;
    }
    if (node is! Map) continue;
    final map = Map<String, dynamic>.from(node);
    final tag = (map['tag'] as String? ?? '').toLowerCase();
    final content = map['content'] is List
        ? map['content'] as List
        : const <dynamic>[];
    switch (tag) {
      case 'p':
        _addText(blocks, content, baseUrl);
      case 'h1':
        _addText(blocks, content, baseUrl, builder: IvHeaderBlock.new);
      case 'h2':
        _addText(blocks, content, baseUrl, builder: IvSubheaderBlock.new);
      case 'h3' || 'h4' || 'h5' || 'h6':
        final level = int.tryParse(tag.substring(1)) ?? 3;
        _addText(
          blocks,
          content,
          baseUrl,
          builder: (text) =>
              IvSectionHeadingBlock(text: text, size: (level - 2).clamp(1, 4)),
        );
      case 'pre':
        final text = ivTextToPlain(_webInline(content, baseUrl)).trimRight();
        if (text.trim().isNotEmpty) {
          blocks.add(IvPreformattedBlock(text: IvTextPlain(text)));
        }
      case 'blockquote':
        final inner = _webBlocks(content, baseUrl);
        if (inner.isNotEmpty) {
          blocks.add(IvBlockQuoteBlock(blocks: inner));
        }
      case 'ul' || 'ol':
        final items = _webListItems(content, baseUrl, ordered: tag == 'ol');
        if (items.isNotEmpty) blocks.add(IvListBlock(items));
      case 'li':
        _addText(blocks, content, baseUrl);
      case 'hr':
        blocks.add(const IvDividerBlock());
      case 'figure':
        final photo = _webFigure(map, content, baseUrl);
        if (photo != null) blocks.add(photo);
      case 'img':
        final photo = _webPhoto(map, baseUrl);
        if (photo != null) {
          blocks.add(IvPhotoBlock(photo: photo.photo, caption: photo.caption));
        }
      case 'table':
        final table = _webTable(map, content, baseUrl);
        if (table != null) blocks.add(table);
      case 'details':
        final details = _webDetails(content, baseUrl);
        if (details != null) blocks.add(details);
      case 'br' || 'wbr' || 'meta':
        break;
      case 'b' ||
          'strong' ||
          'i' ||
          'em' ||
          's' ||
          'del' ||
          'a' ||
          'code' ||
          'mark' ||
          'sub' ||
          'sup' ||
          'span' ||
          'q' ||
          'cite' ||
          'bdi':
        _addText(blocks, [map], baseUrl);
      default:
        if (content.isNotEmpty) blocks.addAll(_webBlocks(content, baseUrl));
    }
  }
  return blocks;
}

void _addText(
  List<IvBlock> blocks,
  List<dynamic> content,
  String baseUrl, {
  IvBlock Function(IvText text)? builder,
}) {
  final text = _webInline(content, baseUrl);
  if (ivTextToPlain(text).trim().isEmpty) return;
  blocks.add(builder != null ? builder(text) : IvParagraphBlock(text));
}

// ---------------------------------------------------------------------------
// Inline text
// ---------------------------------------------------------------------------

IvText _webInline(List<dynamic> nodes, String baseUrl) {
  final runs = <IvText>[];
  for (final node in nodes) {
    if (node is String) {
      if (node.isNotEmpty) runs.add(IvTextPlain(node));
      continue;
    }
    if (node is! Map) continue;
    final map = Map<String, dynamic>.from(node);
    final tag = (map['tag'] as String? ?? '').toLowerCase();
    final content = map['content'] is List
        ? map['content'] as List
        : const <dynamic>[];
    switch (tag) {
      case 'br':
        runs.add(const IvTextPlain('\n'));
      case 'img':
        break;
      case 'a':
        final href = (map['href'] as String? ?? '').trim();
        final child = _webInline(content, baseUrl);
        runs.add(_webLink(href, child, baseUrl));
      case 'b' || 'strong':
        runs.add(IvTextStyled(IvTextStyle.bold, _webInline(content, baseUrl)));
      case 'i' || 'em':
        runs.add(
          IvTextStyled(IvTextStyle.italic, _webInline(content, baseUrl)),
        );
      case 's' || 'del':
        runs.add(
          IvTextStyled(IvTextStyle.strikethrough, _webInline(content, baseUrl)),
        );
      case 'code':
        runs.add(IvTextStyled(IvTextStyle.fixed, _webInline(content, baseUrl)));
      case 'mark':
        runs.add(
          IvTextStyled(IvTextStyle.marked, _webInline(content, baseUrl)),
        );
      case 'sub':
        runs.add(
          IvTextStyled(IvTextStyle.subscript, _webInline(content, baseUrl)),
        );
      case 'sup':
        runs.add(
          IvTextStyled(IvTextStyle.superscript, _webInline(content, baseUrl)),
        );
      case 'p':
        runs.add(_webInline(content, baseUrl));
        runs.add(const IvTextPlain('\n'));
      default:
        var child = _webInline(content, baseUrl);
        // `instant.js` promotes computed font weight/style to attributes, so a
        // span styled bold without a <b> keeps its emphasis.
        if (map['italic'] == 1 || map['italic'] == '1') {
          child = IvTextStyled(IvTextStyle.italic, child);
        }
        if (map['bold'] == 1 || map['bold'] == '1') {
          child = IvTextStyled(IvTextStyle.bold, child);
        }
        runs.add(child);
    }
  }
  if (runs.isEmpty) return const IvTextPlain('');
  return runs.length == 1 ? runs.first : IvTextConcat(runs);
}

IvText _webLink(String href, IvText child, String baseUrl) {
  if (href.isEmpty || href == 'null') return child;
  if (href.startsWith('#')) {
    return IvTextLink(
      kind: IvLinkKind.anchorLink,
      value: href.substring(1),
      child: child,
      fallbackUrl: _resolve(href, baseUrl),
    );
  }
  if (href.startsWith('mailto:')) {
    return IvTextLink(
      kind: IvLinkKind.email,
      value: href.substring(7),
      child: child,
      fallbackUrl: href,
    );
  }
  if (href.startsWith('tel:')) {
    return IvTextLink(
      kind: IvLinkKind.phone,
      value: href.substring(4),
      child: child,
      fallbackUrl: href,
    );
  }
  final resolved = _resolve(href, baseUrl);
  if (resolved.isEmpty) return child;
  return IvTextLink(
    kind: IvLinkKind.url,
    value: resolved,
    child: child,
    fallbackUrl: resolved,
  );
}

String _resolve(String href, String baseUrl) {
  final uri = Uri.tryParse(href);
  if (uri == null) return '';
  if (uri.hasScheme) return href;
  final base = Uri.tryParse(baseUrl);
  if (base == null) return href;
  return base.resolveUri(uri).toString();
}

// ---------------------------------------------------------------------------
// Lists, tables, details, media
// ---------------------------------------------------------------------------

List<IvListItem> _webListItems(
  List<dynamic> content,
  String baseUrl, {
  required bool ordered,
}) {
  final items = <IvListItem>[];
  for (final node in content) {
    if (node is! Map) continue;
    final map = Map<String, dynamic>.from(node);
    if ((map['tag'] as String? ?? '').toLowerCase() != 'li') continue;
    final inner = map['content'] is List
        ? map['content'] as List
        : const <dynamic>[];
    final text = _webInline(inner, baseUrl);
    final plain = ivTextToPlain(text).trim();
    if (plain.isEmpty) continue;
    items.add(
      IvListItem(
        label: '',
        blocks: [IvParagraphBlock(text)],
        value: items.length + 1,
        type: ordered ? '1' : '',
      ),
    );
  }
  return items;
}

IvTableBlock? _webTable(
  Map<String, dynamic> map,
  List<dynamic> content,
  String baseUrl,
) {
  final rows = <List<IvTableCell>>[];
  IvText caption = const IvTextPlain('');
  for (final node in content) {
    if (node is! Map) continue;
    final row = Map<String, dynamic>.from(node);
    final tag = (row['tag'] as String? ?? '').toLowerCase();
    final rowContent = row['content'] is List
        ? row['content'] as List
        : const <dynamic>[];
    if (tag == 'caption') {
      caption = _webInline(rowContent, baseUrl);
      continue;
    }
    if (tag == 'tr') {
      final cells = <IvTableCell>[];
      for (final cellNode in rowContent) {
        if (cellNode is! Map) continue;
        final cell = Map<String, dynamic>.from(cellNode);
        final cellTag = (cell['tag'] as String? ?? '').toLowerCase();
        if (cellTag != 'td' && cellTag != 'th') continue;
        final cellContent = cell['content'] is List
            ? cell['content'] as List
            : const <dynamic>[];
        cells.add(
          IvTableCell(
            text: _webInline(cellContent, baseUrl),
            isHeader: cellTag == 'th',
            colspan: int.tryParse('${cell['colspan'] ?? ''}') ?? 1,
            rowspan: int.tryParse('${cell['rowspan'] ?? ''}') ?? 1,
          ),
        );
      }
      if (cells.isNotEmpty) rows.add(cells);
      continue;
    }
    // tbody/thead/tfoot wrap rows.
    if (tag == 'tbody' || tag == 'thead' || tag == 'tfoot') {
      final nested = _webTable(row, rowContent, baseUrl);
      if (nested != null) rows.addAll(nested.cells);
    }
  }
  if (rows.isEmpty) return null;
  return IvTableBlock(caption: caption, cells: rows);
}

IvDetailsBlock? _webDetails(List<dynamic> content, String baseUrl) {
  if (content.isEmpty) return null;
  IvText header = const IvTextPlain('');
  final rest = <dynamic>[];
  for (final node in content) {
    if (node is Map && (node['tag'] as String? ?? '') == 'summary') {
      final inner = node['content'] is List
          ? node['content'] as List
          : const <dynamic>[];
      header = _webInline(inner, baseUrl);
    } else {
      rest.add(node);
    }
  }
  final blocks = _webBlocks(rest, baseUrl);
  if (blocks.isEmpty) return null;
  return IvDetailsBlock(header: header, blocks: blocks);
}

IvPhotoBlock? _webFigure(
  Map<String, dynamic> figure,
  List<dynamic> content,
  String baseUrl,
) {
  // Wikipedia wraps the image in a link: figure > a > img.
  final image = _findTag(content, const {'img'});
  final captionNode = _findTag(content, const {'figcaption', 'caption'});
  final caption = captionNode == null
      ? const IvTextPlain('')
      : _webInline(
          captionNode['content'] is List
              ? captionNode['content'] as List
              : const <dynamic>[],
          baseUrl,
        );
  if (image == null) return null;
  final photo = _webPhoto(image, baseUrl);
  if (photo == null) return null;
  // The visible figcaption wins over the alt text; alt only fills in when the
  // figure has no caption element.
  return IvPhotoBlock(
    photo: photo.photo,
    caption: ivTextToPlain(caption).trim().isEmpty
        ? photo.caption
        : IvCaption(text: caption),
  );
}

Map<String, dynamic>? _findTag(List<dynamic> nodes, Set<String> tags) {
  for (final node in nodes) {
    if (node is! Map) continue;
    final map = Map<String, dynamic>.from(node);
    if (tags.contains((map['tag'] as String? ?? '').toLowerCase())) {
      return map;
    }
    final inner = map['content'];
    if (inner is List) {
      final found = _findTag(inner, tags);
      if (found != null) return found;
    }
  }
  return null;
}

({IvPhoto photo, IvCaption caption})? _webPhoto(
  Map<String, dynamic> map,
  String baseUrl,
) {
  final src = _imageSource(map);
  if (src.isEmpty) return null;
  final width = int.tryParse('${map['width'] ?? map['data-file-width'] ?? ''}');
  final height = int.tryParse(
    '${map['height'] ?? map['data-file-height'] ?? ''}',
  );
  // Icons and tracking pixels: Wikipedia ships a row of 10×10 pencil icons.
  if (width != null && height != null && width < 32 && height < 32) return null;
  final alt = (map['alt'] as String? ?? '').trim();
  return (
    photo: IvPhoto(
      media: const MediaAttachment(),
      url: src,
      width: width,
      height: height,
    ),
    caption: alt.isEmpty || alt == 'null'
        ? const IvCaption()
        : IvCaption(text: IvTextPlain(alt)),
  );
}

String _imageSource(Map<String, dynamic> map) {
  final src = (map['src'] as String? ?? '').trim();
  final srcset = (map['srcset'] as String? ?? '').trim();
  if (src.isNotEmpty && !src.startsWith('data:')) return src;
  if (srcset.isNotEmpty) {
    final first = srcset.split(',').first.trim().split(' ').first.trim();
    if (first.isNotEmpty) return first;
  }
  return src;
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/// Decodes what `runJavaScriptReturningResult` returns for `instant.js`.
///
/// Android hands back the JS string JSON-encoded (outer quotes and escapes),
/// WKWebView hands it back raw; both end in the extractor's own JSON or
/// `'null'`.
Map<String, dynamic>? decodeInstantViewWebResult(Object? raw) {
  if (raw is! String) return null;
  var text = raw.trim();
  if (text.isEmpty || text == 'null' || text == '""') return null;
  if (text.startsWith('"')) {
    try {
      text = jsonDecode(text) as String;
    } catch (_) {
      return null;
    }
  }
  if (text.isEmpty || text == 'null') return null;
  try {
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

String? _scriptCache;

/// The patched Telegram extractor, injected into the in-app browser's WebView
/// by its "Open local Instant View" action.
Future<String> instantViewExtractionScript() async {
  final cached = _scriptCache;
  if (cached != null) return cached;
  final loaded = await rootBundle.loadString('assets/instant_view/instant.js');
  _scriptCache = loaded;
  return loaded;
}
