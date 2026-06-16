//! parse/semantic 디스크 캐시 무효화 키 — #4438.
//!
//! 캐시 엔트리가 stale 인지 판정하는 u64 키를 계산한다. 키가 다르면 캐시를 버리고 재파싱
//! (fail-safe). 핵심 원칙: **결과에 영향을 주는 입력이 키에 빠지면 "옵션 바꿨는데 옛 결과가
//! 나오는" silent miscompile** 이므로, 입력 누락을 구조적으로 막는 것이 전부다.
//!
//! ## 캐시 단위 = pre-transform parse+semantic
//! module_codec 이 직렬화하는 것은 한 모듈의 **AST + ModuleSemanticData** 다. parse+semantic
//! 단계(`Scanner`+`Parser`+`SemanticAnalyzer`)는 입력으로 **source 바이트 + parser/analyzer
//! 모드 플래그**(is_ts/is_jsx/is_module/is_flow/is_strict)만 읽고 **transform 옵션은 읽지
//! 않는다**(define/jsx_transform/decorators 등은 그 다음 transform pre-pass 가 읽음). 따라서
//! pre-transform 캐시의 키는 source + parse_flags + 버전 가드면 충분하다.
//!
//! ## 보수 vs 정밀 (두 전략)
//! `compute` 는 전략 무관하게 `options_hash` 를 받아 키를 조립한다. 전략은 그 options_hash 를
//! 무엇으로 채우느냐의 차이:
//! - **보수(production 기본)**: 빌드 옵션 **전체**를 해시(`compiled_cache.hashEmitOptions` 같은
//!   complete·guarded 해시를 graph 통합 PR 이 주입). 옵션 하나라도 다르면 무효화 → silent
//!   miscompile 0. 단점은 emit-only 옵션 변경 시도 무효화(과도) — 전체-옵션 해시 전략.
//! - **정밀(후보)**: parse/pre-pass 에 영향을 주는 옵션만(`SelectiveOptions`) 해시. emit-only
//!   옵션 변경 시 캐시 유지(이득). pre-transform 캐시에서는 transform 옵션 전부 제외 가능
//!   (parse+semantic 이 안 읽으므로 **구조적으로 안전**). post-transform 캐시로 확장 시엔
//!   graph 통합의 `cache ON==OFF` byte-identical 동등성 테스트로 안전성을 실증해야 한다.
//!
//! ## graph 통합 시 caller 가 지켜야 할 wiring 불변식 (어기면 silent miscompile)
//! - `source_hash` 는 **plugin transform/load 훅 적용 후** `module.source` 기준으로 계산한다
//!   (raw 파일이 아니라 — plugin 이 바꾼 바이트가 parse 입력이므로).
//! - `ParseFlags` 는 확장자/`module_type` 가 아니라 **설정 완료된 parser 의 effective 상태**
//!   (`source_mode==.ts`/`is_jsx`/`is_module`/`is_flow`/`is_strict_mode`)에서 뽑는다 —
//!   `--platform=react-native`(jsx_in_js)/`--flow`/loader override 가 이를 바꾸기 때문.
//! - 이 캐시는 **bundler parse 설정**을 전제한다: `enable_stmt_info≡true`(false 면 serialized
//!   `references` 가 달라짐), `source_mode` 는 `.ts`/`.js_strict`(transpile 경로의 `.js_lenient`
//!   미사용). transpile 경로와 캐시를 공유하려면 이 둘을 키에 추가해야 한다.
//!
//! ## 비책임 (후속 PR)
//! `compiler_build_id`(zts 빌드 식별자) 실제 값은 caller(graph 통합 PR)가 build.zig `addOptions`
//! 로 주입한 git SHA 등으로 채운다. 여기선 입력 파라미터로만 받는다. graph cache-hit 연결도 후속.

const std = @import("std");
const InputHasher = @import("compiled_cache.zig").InputHasher;
const ast_codec = @import("../parser/ast_codec.zig");
const semantic_codec = @import("semantic_codec.zig");
const module_codec = @import("module_codec.zig");

const KEY_SEED: u64 = 0x5A4E5443_4B4559; // "ZNTC""KEY"
const OPTS_SEED: u64 = 0x5A4E5443_4F5054; // "ZNTC""OPT"

// 각 codec 포맷 버전은 16-bit 슬롯(bits 32-47 / 16-31 / 0-15)을 차지한다. 0xFFFF 초과 시
// 인접 슬롯과 겹쳐 서로 다른 버전 조합이 충돌(→ 호환 안 되는 포맷의 stale 역직렬화)하므로 막는다.
comptime {
    if (ast_codec.FORMAT_VERSION > 0xFFFF or
        semantic_codec.FORMAT_VERSION > 0xFFFF or
        module_codec.FORMAT_VERSION > 0xFFFF)
        @compileError("codec FORMAT_VERSION 이 16-bit 슬롯을 초과 — CODEC_FORMAT 패킹 폭을 넓힐 것.");
}

/// 3개 codec 포맷 버전 조합(16-bit 슬롯). 어느 포맷이든 bump 되면 키가 바뀌어 구버전 캐시 전량
/// 무효화 — relocatable 바이트 레이아웃·Span 의미가 버전마다 달라 역직렬화하면 위험(포맷 버전 가드).
pub const CODEC_FORMAT: u64 =
    (@as(u64, ast_codec.FORMAT_VERSION) << 32) |
    (@as(u64, semantic_codec.FORMAT_VERSION) << 16) |
    @as(u64, module_codec.FORMAT_VERSION);

/// parse+semantic 결과(AST 모양/심볼)를 직접 결정하는 파서/분석기 모드 플래그.
pub const ParseFlags = packed struct(u8) {
    is_ts: bool = false,
    is_jsx: bool = false,
    is_module: bool = false,
    is_flow: bool = false,
    is_strict: bool = false,
    _pad: u3 = 0,

    pub fn bits(self: ParseFlags) u32 {
        return @as(u8, @bitCast(self));
    }
};

/// **정밀 전략**이 키에 넣는, parse/pre-pass 에 영향을 주는 옵션의 명시적 집합 —
/// `TransformOptions` 에서 결과에 영향을 주는 필드를 **손으로 추린** 것이다.
/// 단순 타입(bool/정수/enum)만 허용한다 — 슬라이스/포인터(define/plugins 등)는 caller 가
/// 미리 u64 로 해시해 넣는다(아래 `*_hash` 필드). `hashSelective` 가 comptime reflection 으로
/// 모든 필드를 자동 해시하므로 **이 struct 내부** 필드 누락은 불가능하고, 복합 타입을 추가하면
/// `hashSelective` 가 컴파일 에러를 낸다.
///
/// ⚠️ 단, reflection 은 `TransformOptions` 에 **새 parse-영향 필드가 생겨도 자동 전파하지
/// 않는다**(정밀 전략의 근본 위험 — 누락 시 silent miscompile). 아래 comptime 가드가
/// TransformOptions 필드 수를 못박아, 변경 시 SelectiveOptions 분류 재검토를 강제한다.
pub const SelectiveOptions = struct {
    // class field / decorator 다운레벨 (AST 변형)
    experimental_decorators: bool = false,
    emit_decorator_metadata: bool = false,
    use_define_for_class_fields: bool = true,
    // JSX lowering
    jsx_transform: bool = false,
    jsx_runtime: u8 = 0, // codegen_options.JsxRuntime 의 @intFromEnum
    jsx_factory_hash: u64 = 0,
    jsx_fragment_hash: u64 = 0,
    jsx_import_source_hash: u64 = 0,
    // dead-code / 치환 (AST 변형)
    drop_console: bool = false,
    drop_debugger: bool = false,
    drop_labels_hash: u64 = 0,
    define_hash: u64 = 0,
    module_specifier_map_hash: u64 = 0,
    // minify 중 AST 를 바꾸는 것 (pre-pass)
    minify_syntax: bool = false,
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    // pre-pass 게이트 트랜스폼
    react_refresh: bool = false,
    styled_components: bool = false,
    emotion: bool = false,
    worklet_transform: bool = false,
    // ES 다운레벨 범위 (unsupported feature set 의 사전해시)
    unsupported_hash: u64 = 0,
};

comptime {
    // SelectiveOptions ↔ TransformOptions 동기화 강제(정밀 전략 안전망). TransformOptions 에
    // 필드가 추가되면 컴파일 에러 → 그 필드가 parse/semantic(pre-pass) 결과에 영향을 주는지
    // 판정해서, 주면 SelectiveOptions 에 반영하고 이 수를 갱신할 것(누락=silent miscompile).
    const tf_fields = @typeInfo(@import("../transformer/options.zig").TransformOptions).@"struct".fields.len;
    if (tf_fields != 45)
        @compileError("TransformOptions 필드 수 변경 — 새 필드의 parse-영향 여부 판정 후 SelectiveOptions 갱신 + 이 수 갱신 필요.");
}

/// `SelectiveOptions` 의 모든 필드를 reflection 으로 해시(정밀 전략 options_hash).
pub fn hashSelective(o: *const SelectiveOptions) u64 {
    var h = InputHasher.init(OPTS_SEED);
    inline for (@typeInfo(SelectiveOptions).@"struct".fields) |f| {
        const v = @field(o.*, f.name);
        switch (@typeInfo(f.type)) {
            .bool => h.addBool(v),
            .int => h.addU64(@intCast(v)),
            .@"enum" => h.addU64(@intFromEnum(v)),
            else => @compileError("cache_key: SelectiveOptions." ++ f.name ++
                " 타입은 reflection 해시 미지원 — caller 가 u64 로 사전해시(`*_hash` 필드)해 넣을 것."),
        }
    }
    return h.final();
}

/// 무효화 키 조립. `options_hash` 는 전략에 따라 보수(전체)/정밀(`hashSelective`) 중 하나.
/// `source_hash` = 파일 내용 wyhash(plugin transform 후 source 기준 — 위 wiring 불변식 참조).
/// `compiler_build_id` = zts 빌드 식별자(graph PR 가 build.zig git SHA 등으로 주입).
/// ⚠️ `compiler_build_id == 0` 은 컴파일러 버전 가드를 **무력화**한다(parser/semantic 로직이
/// 바뀐 rebuild 후에도 같은 키 → stale miscompile). caller 는 0 이 아닌 실제 빌드 식별자를 줄 것.
pub fn compute(source_hash: u64, flags: ParseFlags, options_hash: u64, compiler_build_id: u64) u64 {
    var h = InputHasher.init(KEY_SEED);
    h.addU64(source_hash);
    h.addU32(flags.bits());
    h.addU64(options_hash);
    h.addU64(CODEC_FORMAT);
    h.addU64(compiler_build_id);
    return h.final();
}
