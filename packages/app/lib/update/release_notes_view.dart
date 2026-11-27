import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

/// 发布说明正文的 Markdown 视图。
///
/// 上游 `ReleaseInfo.notes` 是 GitHub release 的 body，本身是 Markdown：
/// `#`/`##` 标题、`-` 列表、`**粗体**`、`` `代码` ``、`[文字](链接)`。
/// 直接塞进 [SelectableText] 会把 `-` 和 `#` 当成正文念出来，在十英尺的
/// TV 上尤其刺眼。这里用 `markdown` 包（Flutter 官方 markdown 渲染器的
/// 底层解析器）把 Markdown 解析成 AST，再铺成富文本：标题、列表、粗体、
/// 斜体、行内代码、链接、分隔线与代码块都按语义渲染，未知语法交给库按
/// CommonMark 规则处理，不再自己维护一套正则。
///
/// 仍然是 [SelectableText]：既能选中复制链接，也让现有按类型找它的测试
/// 契约不破（key 保持 `发布说明正文`，列表项仍带 `•`）。TV 与手机共用
/// 同一份解析，只是字号不同。
class ReleaseNotesView extends StatelessWidget {
  final String markdown;
  final double fontSize;

  const ReleaseNotesView({
    super.key,
    required this.markdown,
    this.fontSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final nodes = md.Document().parse(markdown.replaceAll('\r\n', '\n'));
    return SelectableText.rich(
      key: const Key('发布说明正文'),
      TextSpan(
        style: TextStyle(
          fontSize: fontSize,
          height: 1.5,
          color: scheme.onSurface,
        ),
        children: [
          for (final node in nodes) ..._nodeSpans(node, scheme, fontSize),
        ],
      ),
    );
  }

  /// 把一个块级节点铺成一组 span。块之间补单个换行形成段落间距；列表项
  /// 自带 `•` 前缀与自己的换行，避免额外空行把 TV 正文撑得过长。
  static List<InlineSpan> _nodeSpans(
    md.Node node,
    ColorScheme scheme,
    double fontSize,
  ) {
    if (node is md.Text) return [TextSpan(text: node.text)];

    final element = node as md.Element;
    final tag = element.tag;
    final children = element.children ?? const <md.Node>[];

    switch (tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final level = int.parse(tag.substring(1));
        return [
          TextSpan(
            style: TextStyle(
              fontSize: fontSize + _headingDelta(level),
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
            children: [
              for (final child in children) ..._nodeSpans(child, scheme, fontSize),
            ],
          ),
          const TextSpan(text: '\n'),
        ];

      case 'ul':
      case 'ol':
        final spans = <InlineSpan>[];
        for (final item in children) {
          if (item is! md.Element || item.tag != 'li') {
            spans.addAll(_nodeSpans(item, scheme, fontSize));
            continue;
          }
          spans.add(
            TextSpan(
              children: [
                TextSpan(text: '  •  ', style: TextStyle(color: scheme.primary)),
                for (final child in item.children ?? const <md.Node>[])
                  ..._nodeSpans(child, scheme, fontSize),
                const TextSpan(text: '\n'),
              ],
            ),
          );
        }
        return spans;

      case 'li':
        // A list item reached outside a ul/ol still gets its bullet.
        return [
          TextSpan(text: '  •  ', style: TextStyle(color: scheme.primary)),
          for (final child in children) ..._nodeSpans(child, scheme, fontSize),
          const TextSpan(text: '\n'),
        ];

      case 'p':
        return [
          for (final child in children) ..._nodeSpans(child, scheme, fontSize),
          const TextSpan(text: '\n'),
        ];

      case 'br':
        return const [TextSpan(text: '\n')];

      case 'hr':
        return const [TextSpan(text: '\n────────\n')];

      case 'pre':
      case 'codeblock':
        // Fenced/indented code arrives as <pre><code>…</code></pre>.
        final codeText = element.textContent;
        return [
          TextSpan(
            text: codeText,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: fontSize - 1,
              color: scheme.onSurface,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          const TextSpan(text: '\n'),
        ];

      case 'strong':
      case 'b':
        return [
          TextSpan(
            style: const TextStyle(fontWeight: FontWeight.w700),
            children: [
              for (final child in children) ..._nodeSpans(child, scheme, fontSize),
            ],
          ),
        ];

      case 'em':
      case 'i':
        return [
          TextSpan(
            style: const TextStyle(fontStyle: FontStyle.italic),
            children: [
              for (final child in children) ..._nodeSpans(child, scheme, fontSize),
            ],
          ),
        ];

      case 'code':
        return [
          TextSpan(
            text: element.textContent,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: fontSize - 1,
              color: scheme.primary,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ];

      case 'a':
        // Show the label, not the URL: the dialog already offers the release
        // page below, and a raw https:// line is noise on a ten-foot screen.
        return [
          TextSpan(
            text: element.textContent,
            style: TextStyle(
              color: scheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
        ];

      case 'blockquote':
        return [
          for (final child in children) ..._nodeSpans(child, scheme, fontSize),
        ];

      default:
        // Unknown block tags: keep their text rather than dropping content.
        if (children.isEmpty) {
          return [TextSpan(text: element.textContent)];
        }
        return [
          for (final child in children) ..._nodeSpans(child, scheme, fontSize),
        ];
    }
  }

  /// 级别 1 最大、6 最小；最低仍不小于正文，避免标题反而比正文难读。
  static double _headingDelta(int level) =>
      ((7 - level) * 1.5).clamp(0.0, 9.0).toDouble();
}
