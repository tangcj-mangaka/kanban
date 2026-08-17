import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('areConcurrent', () {
    test('双方都没见过对方 → 并发', () {
      // 两台设备都在只知道到 100 号时各自改了同一个字段，
      // 后来分别拿到 101 和 102。
      expect(
        areConcurrent(aSeq: 101, aBaseSeq: 100, bSeq: 102, bBaseSeq: 100),
        isTrue,
      );
    });

    test('后者是在看过前者之后改的 → 不是并发', () {
      // b 产生时已经知道到 101，也就是已经看见了 a。这是正常的先后修改。
      expect(
        areConcurrent(aSeq: 101, aBaseSeq: 100, bSeq: 102, bBaseSeq: 101),
        isFalse,
      );
    });

    test('这是笔记本一直在线那种情况——光看 seq 会漏判', () {
      // 笔记本兼做服务器，改动立刻拿到 101 号；手机离线时也改了
      // （当时只知道到 100），回家连上拿到 102 号。
      //
      // 等笔记本收到手机那条时，自己那条早就有号了。所以「本地还没同步
      // 的改动被覆盖」这种判据在这里失效，必须靠 baseSeq。
      expect(
        areConcurrent(aSeq: 101, aBaseSeq: 100, bSeq: 102, bBaseSeq: 100),
        isTrue,
        reason: '两边都是在只知道 100 号时改的，是真并发',
      );
    });

    test('还没同步的 op 不判并发', () {
      // 没有序号就无从判断谁在谁之前。等 ACK 回来再说。
      expect(
        areConcurrent(aSeq: null, aBaseSeq: 100, bSeq: 102, bBaseSeq: 100),
        isFalse,
      );
    });

    test('缺 baseSeq（旧版本产生的 op）时不报冲突', () {
      // 宁可漏报也不错报：错报会让人白跑一趟去核对两份其实没冲突的内容。
      expect(
        areConcurrent(aSeq: 101, aBaseSeq: null, bSeq: 102, bBaseSeq: 100),
        isFalse,
      );
      expect(
        areConcurrent(aSeq: 101, aBaseSeq: 100, bSeq: 102, bBaseSeq: null),
        isFalse,
      );
    });

    test('对称：谁在前谁在后不影响判定', () {
      expect(
        areConcurrent(aSeq: 102, aBaseSeq: 100, bSeq: 101, bBaseSeq: 100),
        isTrue,
      );
    });

    test('从没同步过的两台设备（baseSeq 都是 0）也能判', () {
      expect(
        areConcurrent(aSeq: 1, aBaseSeq: 0, bSeq: 2, bBaseSeq: 0),
        isTrue,
      );
    });
  });

  group('Op 的 baseSeq', () {
    Op op({int? seq, int? baseSeq}) => Op(
      seq: seq,
      opId: 'x',
      boardId: 'b',
      entity: Entity.card,
      entityId: 'c',
      field: CardF.title,
      value: 'v',
      deviceId: 'd',
      wallTs: 1,
      baseSeq: baseSeq,
    );

    test('往返 JSON 保留 baseSeq', () {
      expect(Op.fromJson(op(seq: 5, baseSeq: 3).toJson()).baseSeq, 3);
    });

    test('没有 base_seq 字段的旧消息仍能解析', () {
      final json = op(seq: 5, baseSeq: 3).toJson()..remove('base_seq');
      expect(Op.fromJson(json).baseSeq, isNull);
    });

    test('withSeq 不丢 baseSeq', () {
      // ACK 回填序号时如果把 baseSeq 丢了，之后就再也判不出并发。
      expect(op(baseSeq: 7).withSeq(9).baseSeq, 7);
    });
  });
}
