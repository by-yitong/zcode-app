// buildQuestionAnswerContent 纯函数测试
// (构造规则逐字对齐网页端 asar renderer 的 Vat() 函数)。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/providers/chat_provider.dart';

QuestionItem _q(
  String text, {
  bool multiSelect = false,
  List<QuestionOption> options = const [],
}) =>
    QuestionItem(
      question: text,
      multiSelect: multiSelect,
      options: options,
    );

void main() {
  group('buildQuestionAnswerContent', () {
    test('单题单选: answers + answer_0 + answer 同值字符串', () {
      final content = buildQuestionAnswerContent(
        [_q('用什么语言?', options: const [
          QuestionOption(value: 'v1', label: '中文'),
          QuestionOption(value: 'v2', label: '英文'),
        ])],
        {0: ['v1']},
        {},
      );
      expect(content, {
        'answers': {'用什么语言?': 'v1'},
        'answer_0': 'v1',
        'answer': 'v1',
      });
    });

    test('单题多选: answer_0/answer 为 value 数组', () {
      final content = buildQuestionAnswerContent(
        [_q('选框架?', multiSelect: true, options: const [
          QuestionOption(value: 'flutter', label: 'Flutter'),
          QuestionOption(value: 'rn', label: 'React Native'),
        ])],
        {0: ['flutter', 'rn']},
        {},
      );
      expect(content, {
        'answers': {'选框架?': 'flutter, rn'},
        'answer_0': ['flutter', 'rn'],
        'answer': ['flutter', 'rn'],
      });
    });

    test('两题: answer_0 + answer_1, 无 answer 键, answers 两键', () {
      final content = buildQuestionAnswerContent(
        [
          _q('第一题?'),
          _q('第二题?', multiSelect: true, options: const [
            QuestionOption(value: 'a', label: 'A'),
            QuestionOption(value: 'b', label: 'B'),
          ]),
        ],
        {1: ['a', 'b']},
        {0: '好的'},
      );
      expect(content, {
        'answers': {
          '第一题?': '好的',
          '第二题?': 'a, b',
        },
        'answer_0': '好的',
        'answer_1': ['a', 'b'],
      });
      expect(content.containsKey('answer'), isFalse);
    });

    test('某题无选择且无自定义 → 整题跳过 (answers/answer_i 均无该题)', () {
      final content = buildQuestionAnswerContent(
        [
          _q('跳过的题?', options: const [
            QuestionOption(value: 'x', label: 'X'),
          ]),
          _q('答了的题?'),
        ],
        {},
        {1: '跳过第一题'},
      );
      expect(content, {
        'answers': {'答了的题?': '跳过第一题'},
        'answer_1': '跳过第一题',
        // 单题追加 answer 的规则只在 questions.length === 1 时生效
      });
      expect(content.containsKey('answer_0'), isFalse);
      expect(content.containsKey('answer'), isFalse);
    });

    test('自定义文本 trim 非空追加到 vals 尾部; 全空白不追加', () {
      // 非空自定义 + 已选选项: 文本追加到 vals 尾部 (answers 体现拼接;
      // 单选 answer_0 按 vals[0] 只取首元素, 网页端同款)
      final withCustom = buildQuestionAnswerContent(
        [_q('选颜色?', options: const [
          QuestionOption(value: 'red', label: '红'),
        ])],
        {0: ['red']},
        {0: '  其他: 蓝色  '},
      );
      expect(
        (withCustom['answers'] as Map<String, String>)['选颜色?'],
        'red, 其他: 蓝色',
      );
      expect(withCustom['answer_0'], 'red');
      expect(withCustom['answer'], 'red');

      // 多选: answer 数组完整体现追加到尾部
      final multiCustom = buildQuestionAnswerContent(
        [_q('选颜色?', multiSelect: true, options: const [
          QuestionOption(value: 'red', label: '红'),
        ])],
        {0: ['red']},
        {0: '蓝色'},
      );
      expect(multiCustom['answer_0'], ['red', '蓝色']);

      // 全空白自定义 → 不追加
      final blank = buildQuestionAnswerContent(
        [_q('选颜色?', options: const [
          QuestionOption(value: 'red', label: '红'),
        ])],
        {0: ['red']},
        {0: '   '},
      );
      expect(blank['answer_0'], 'red');
      expect(
        (blank['answers'] as Map<String, String>)['选颜色?'],
        'red',
      );

      // 仅全空白自定义 (未选选项) → 整题跳过
      final onlyBlank = buildQuestionAnswerContent(
        [_q('选颜色?')],
        {},
        {0: ' \t '},
      );
      expect(onlyBlank['answers'], isEmpty);
      expect(onlyBlank.containsKey('answer_0'), isFalse);
    });

    test('value 用选项 value 字段而非 label', () {
      final content = buildQuestionAnswerContent(
        [
          _q('部署方式?', multiSelect: true, options: const [
            QuestionOption(value: 'docker', label: '容器化部署'),
            QuestionOption(value: 'bare', label: '裸机部署'),
          ]),
        ],
        {0: ['docker', 'bare']},
        {},
      );
      // 提交协议取 value, label 仅用于展示
      expect(content['answer_0'], ['docker', 'bare']);
      expect(content['answer'], ['docker', 'bare']);
      expect(content['answers'], {
        '部署方式?': 'docker, bare',
      });
      expect((content['answer_0'] as List).contains('容器化部署'), isFalse);
    });
  });
}
