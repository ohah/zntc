//! ZTS Semantic — 스코프 정의
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

    /// 이 스코프에서 선언된 심볼 수 (디버깅/통계용)
    symbol_count: u16 = 0,
};
