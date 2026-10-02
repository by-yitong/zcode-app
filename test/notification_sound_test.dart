// 任务事件提示音测试 (对齐桌面端 task-notification-sound):
// 1) NotificationSound service — 开关门控 + 异常静默;
// 2) ChatNotifier 三处触发 — 完成 (500ms 防抖确认) / AI 提问 / 权限请求;
//    用户主动停止不触发。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zcode_app/core/feedback/notification_sound.dart';
import 'package:zcode_app/core/relay/relay_client.dart';
import 'package:zcode_app/core/relay/relay_events.dart';
import 'package:zcode_app/providers/chat_provider.dart';

/// 构造最小可用的 ChatNotifier (taskId=null → 不触网不订阅, 等首发消息)。
ChatNotifier _newNotifier(RelayClient relay) {
  final notifier = ChatNotifier(
    relay,
    const ChatRef(taskId: null, workspacePath: '/tmp/ws'),
    preferredModelReader: () => null,
    preferredModelSetter: (_) {},
    mergeDiscovered: (_) {},
  );
  return notifier;
}

/// 权限类挂起交互 (kind=permission)
V4PendingInteraction _permInteraction(String id) => V4PendingInteraction(
  interactionId: id,
  kind: 'permission',
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  permission: V4PermissionPayload(toolCallId: 'tc_$id', toolName: 'Bash'),
);

/// AI 提问类挂起交互 (kind=userInput, 带一道题)
V4PendingInteraction _questionInteraction(String id) => V4PendingInteraction(
  interactionId: id,
  kind: 'userInput',
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  userInput: V4UserInputPayload(
    questions: [
      V4Question(
        question: '继续吗?',
        header: '确认',
        multiSelect: false,
        options: [V4QuestionOption(value: 'yes', label: '继续')],
      ),
    ],
  ),
);

void main() {
  group('NotificationSound service', () {
    setUp(() {
      // 测试环境无 platform channel, 统一走 mock 偏好 (各用例自设键值)
      SharedPreferences.setMockInitialValues({});
    });

    test('默认 (无偏好文件) → 调用注入 player', () async {
      var played = 0;
      final sound = NotificationSound(playOverride: () async => played++);
      await sound.play();
      expect(played, 1);
    });

    test('notification_sound_enabled=false → 不调用', () async {
      SharedPreferences.setMockInitialValues({
        kNotificationSoundPrefKey: false,
      });
      var played = 0;
      final sound = NotificationSound(playOverride: () async => played++);
      await sound.play();
      expect(played, 0);
    });

    test('player 抛异常 → play() 不抛 (静默吞)', () async {
      final sound = NotificationSound(
        playOverride: () async => throw StateError('boom'),
      );
      await expectLater(sound.play(), completes);
    });
  });

  group('ChatNotifier 提示音触发点', () {
    late RelayClient relay;
    late ChatNotifier notifier;
    var soundCalls = 0;

    setUp(() {
      soundCalls = 0;
      relay = RelayClient(
        config: const RelayConfig(
          wsUrl: 'wss://unit.test/ws',
          deviceSid: 'd_unit',
          passHash: 'hash',
          cookie: 'acw_tc=1',
        ),
      );
      notifier = _newNotifier(relay);
      // 注入假提示音记录器
      notifier.setNotificationSoundForTest(() async => soundCalls++);
    });

    tearDown(() {
      notifier.dispose();
      relay.dispose();
    });

    /// 构造 deltas 帧 (state.updated patch)
    V4Frame deltasFrame(List<V4Delta> deltas) => V4Frame(
      topic: 'conversation/unit-test',
      subscriptionId: 'sub',
      fromSeq: 0,
      toSeq: 0,
      sentAt: DateTime.now(),
      payload: V4DeltasPayload(deltas),
    );

    /// 构造 snapshot 帧 (权威全量状态)
    V4Frame snapshotFrame(V4ConversationSnapshot snap) => V4Frame(
      topic: 'conversation/unit-test',
      subscriptionId: 'sub',
      fromSeq: 0,
      toSeq: 0,
      sentAt: DateTime.now(),
      payload: V4SnapshotPayload(snap),
    );

    /// 最小快照 (无行内容, 仅携带挂起交互)
    V4ConversationSnapshot snapWith(List<V4PendingInteraction> interactions) =>
        V4ConversationSnapshot(
          sessionId: 'unit-test',
          control: V4Control(phase: 'draft'),
          config: V4Config(),
          meta: V4Meta(),
          rows: V4Rows(),
          pendingInteractions: interactions,
        );

    test('control patch running→非 running 走完 500ms 防抖 → 响 1 次', () async {
      notifier.debugHandleFrameForTest(
        deltasFrame([
          const V4StateUpdated({
            'control': {'phase': 'running'},
          }),
        ]),
      );
      expect(notifier.state.isResponding, isTrue);
      expect(soundCalls, 0, reason: '进入运行态不响');

      notifier.debugHandleFrameForTest(
        deltasFrame([
          const V4StateUpdated({
            'control': {'phase': 'completedSuccess'},
          }),
        ]),
      );
      expect(soundCalls, 0, reason: '500ms 防抖未到期不响');

      // 等价 tester.pump(600ms): 走完防抖窗口
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(soundCalls, 1, reason: '运行 → 完成 (防抖确认后) 响一声');
    });

    test('用户主动停止 (stop 后 isResponding 已 false) → 不响', () async {
      notifier.debugHandleFrameForTest(
        deltasFrame([
          const V4StateUpdated({
            'control': {'phase': 'running'},
          }),
        ]),
      );
      notifier.debugHandleFrameForTest(
        deltasFrame([
          const V4StateUpdated({
            'control': {'phase': 'completedSuccess'},
          }),
        ]),
      );
      // 模拟 stopResponding 的乐观落 false (在防抖到期前)
      notifier.state = notifier.state.copyWith(isResponding: false);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(soundCalls, 0, reason: '用户主动停止不响 (防抖回调 early-return)');
    });

    test('AI 提问行到达 (pendingQuestion 置位) → 响 1 次', () async {
      notifier.debugHandleFrameForTest(
        snapshotFrame(snapWith([_questionInteraction('q_1')])),
      );
      expect(notifier.state.pendingQuestion, isNotNull);
      expect(soundCalls, 1, reason: 'AI 提问弹窗弹出时响一声');
    });

    test('提问挂起期间重连 → 重复快照携带同一题不重响', () async {
      // 首次快照带题 (prev 为 null) → 响 1 次
      final snap = snapWith([_questionInteraction('q_1')]);
      notifier.debugHandleFrameForTest(snapshotFrame(snap));
      expect(notifier.state.pendingQuestion, isNotNull);
      expect(soundCalls, 1, reason: '首条提问响一声');

      // 断线重连 → resubscribe 快照携带同一挂起题 (保持非空) → 不重响
      notifier.debugHandleFrameForTest(snapshotFrame(snap));
      expect(notifier.state.pendingQuestion, isNotNull);
      expect(soundCalls, 1, reason: '重连重复快照不重复响');
    });

    test('pendingPermissions 空→非空响 1 次; 保持非空再刷新不重复响', () async {
      notifier.debugHandleFrameForTest(
        snapshotFrame(snapWith([_permInteraction('perm_1')])),
      );
      expect(notifier.state.pendingPermissions.length, 1);
      expect(soundCalls, 1, reason: '权限请求首次到达响一声');

      // 权限仍挂起 (保持非空) 的重复快照/刷新 → 不重复响
      notifier.debugHandleFrameForTest(
        snapshotFrame(snapWith([_permInteraction('perm_1')])),
      );
      expect(notifier.state.pendingPermissions.length, 1);
      expect(soundCalls, 1, reason: '保持非空不重复响');
    });

    test('提问经 patch 实时路径到达 → 响 1 次; 幂等刷新不重响', () async {
      // delta 增量帧: wire 形状为 {interactionId, kind, payload} (fromJson 键)
      const questionPatch = {
        'pendingInteractions': [
          {
            'interactionId': 'q_patch_1',
            'kind': 'userInput',
            'payload': {
              'questions': [
                {
                  'question': '继续吗?',
                  'header': '确认',
                  'multiSelect': false,
                  'options': [
                    {'value': 'yes', 'label': '继续'},
                  ],
                },
              ],
            },
          },
        ],
      };
      notifier.debugHandleFrameForTest(
        deltasFrame([const V4StateUpdated(questionPatch)]),
      );
      expect(notifier.state.pendingQuestion, isNotNull);
      expect(soundCalls, 1, reason: '提问经增量 patch 到达弹窗时响一声');

      // 幂等刷新 (pendingQuestion 保持非空) → 不重复响
      notifier.debugHandleFrameForTest(
        deltasFrame([const V4StateUpdated(questionPatch)]),
      );
      expect(notifier.state.pendingQuestion, isNotNull);
      expect(soundCalls, 1, reason: '保持非空的重复 patch 不重复响');
    });
  });
}
