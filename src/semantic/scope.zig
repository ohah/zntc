//! ZNTC Semantic — 스코프 정의
//!
//! 플랫 배열 + 부모 인덱스 방식 (D052, oxc 방식).
//! AST NodeIndex와 동일한 패턴 — u32 인덱스로 참조 (D004).
//!
//! ECMAScript 스코프 종류:
//!   - global: 프로그램 최상위
//!   - function: function/arrow 본문 (var 호이스팅 경계)
//!   - block: {}, if, for, while, switch 등 (let/const 스코핑)
//!   - catch: catch(e) 파라미터 스코프
//!   - class: class body (private 필드 스코프)
//!   - module: ESM 모듈 스코프

const std = @import("std");

/// 스코프 인덱스. scopes 배열의 위치를 가리킨다.
pub const ScopeId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn isNone(self: ScopeId) bool {
        return self == .none;
    }

    pub fn toIndex(self: ScopeId) u32 {
        return @intFromEnum(self);
    }
};

/// 스코프 종류. var 호이스팅 경계와 let/const 스코핑 규칙이 다르다.
pub const ScopeKind = enum(u8) {
    /// 프로그램 최상위 (var 호이스팅 경계)
    global,
    /// function/arrow 본문 (var 호이스팅 경계)
    function,
    /// module 스코프 (var 호이스팅 경계, 항상 strict)
    module,
    /// 블록 스코프: {}, if, for, while 등
    block,
    /// switch 문 스코프
    switch_block,
    /// catch(e) 파라미터 스코프
    catch_clause,
    /// class body 스코프
    class_body,

    /// var 호이스팅 경계인지 (var 선언이 이 스코프까지 끌어올려짐)
    pub fn isVarScope(self: ScopeKind) bool {
        return switch (self) {
            .global, .function, .module => true,
            .block, .switch_block, .catch_clause, .class_body => false,
        };
    }
};

/// 스코프 하나의 데이터.
/// scopes[scope_id]로 접근. 캐시 효율을 위해 작게 유지.
pub const Scope = struct {
    /// 부모 스코프 (global은 ScopeId.none)
    parent: ScopeId,

    /// 스코프 종류
    kind: ScopeKind,

    /// 이 스코프가 strict mode인지
    is_strict: bool,

    /// 이 스코프 또는 자손 스코프에 direct `eval(...)` 호출이 있는지.
    /// true이면 이 스코프에 선언된 바인딩은 mangling되면 안 된다
    /// (eval이 동적으로 이름을 참조할 수 있음). rolldown/oxc 방식.
    subtree_has_direct_eval: bool = false,

    /// 이 스코프 또는 자손 스코프에 `with` 문이 있는지.
    /// true이면 이 스코프 바인딩은 mangling 금지.
    subtree_has_with: bool = false,

    /// 이 스코프에서 선언된 심볼 수 (디버깅/통계용)
    symbol_count: u16 = 0,

    /// 이 스코프에 선언된 바인딩이 direct eval/with으로 인해
    /// 동적 lookup 대상이 될 수 있는지. mangler가 이름 변경을 건너뛰는 기준.
    pub fn blocksMangling(self: Scope) bool {
        return self.subtree_has_direct_eval or self.subtree_has_with;
    }
};

/// `start` 가 속한 **실행 단위**(execution unit) 스코프의 인덱스.
///
/// "실행 단위" = 코드가 *언제* 실행되는지를 가르는 경계 스코프. 같은 실행 단위 안에서는
/// 소스 순서 == 실행 순서(straight-line)지만, 경계를 넘으면 그렇지 않다:
///   - function 본문은 *호출될 때* 실행된다.
///   - class_body(필드 초기화자 / static block)는 *클래스 평가·인스턴스 생성 시점* 에 실행된다.
///   - global / module 은 최상위 실행 단위.
/// block / switch / catch 는 바깥과 실행 시점이 같으므로 경계가 아니다 → 부모로 올라간다.
///
/// dead-store 제거(#4503)처럼 "이 read 가 저 write 사이에 끼어들 수 있는가" 를 판정할 때,
/// 두 참조의 실행 단위가 다르면 소스 순서로는 아무것도 결론지을 수 없다.
///
/// 스코프 체인이 손상됐거나(범위 밖 인덱스) 순환이면 `null` — 호출자가 보수적으로 처리한다.
pub fn enclosingExecUnit(scopes: []const Scope, start: ScopeId) ?u32 {
    var sid = start;
    // 스코프 개수만큼만 거슬러 올라간다 (손상된 parent 체인의 무한 루프 방어).
    var hops: usize = 0;
    while (hops <= scopes.len) : (hops += 1) {
        if (sid.isNone()) return null;
        const idx = sid.toIndex();
        if (idx >= scopes.len) return null;
        const sc = scopes[idx];
        switch (sc.kind) {
            .global, .module, .function, .class_body => return idx,
            .block, .switch_block, .catch_clause => {},
        }
        if (sc.parent.isNone()) return idx; // 루트 도달 — 방어적으로 자기 자신을 단위로.
        sid = sc.parent;
    }
    return null;
}

/// `start` 또는 그 조상 스코프 중 `pred` 를 만족하는 것이 있으면 true.
/// 잘못된 인덱스를 만나면 false (defensive — analyzer 가 항상 valid 한 chain 보장).
pub fn anyAncestor(scopes: []const Scope, start: ScopeId, comptime pred: fn (Scope) bool) bool {
    var sid = start;
    while (!sid.isNone()) {
        const idx = sid.toIndex();
        if (idx >= scopes.len) return false;
        const sc = scopes[idx];
        if (pred(sc)) return true;
        sid = sc.parent;
    }
    return false;
}
