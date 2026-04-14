//! Parser-local import/export scan types.
//!
//! 파서가 AST를 구축하면서 동시에 import/export 정보를 수집할 때 사용하는 타입.
//! bundler의 types.zig, binding_scanner.zig 타입과 유사하지만
//! bundler 의존성 없이 파서 단독으로 사용 가능하다.
//!
//! enable_scan=true일 때만 파서가 이 타입들을 사용하여 레코드/바인딩을 수집하고,
//! graph.zig에서 bundler 타입으로 변환한다.

const Span = @import("../lexer/token.zig").Span;

/// import 종류 — bundler types.ImportKind와 동일한 레이아웃.
pub const ImportKind = enum {
    static_import,
    dynamic_import,
    re_export,
    side_effect,
    require,
    worker,
    glob,
};

/// 파서가 수집하는 import 레코드. bundler ImportRecord의 경량 버전.
pub const ScanImportRecord = struct {
    /// 원본 import 경로 (따옴표 제거됨, 소스 코드 참조)
    specifier: []const u8,
    /// import 종류
    kind: ImportKind,
    /// 소스 문자열의 span (따옴표 포함)
    span: Span,
    /// worker: new URL(...) 전체 범위
    url_span: ?Span = null,
    /// import.meta.glob: eager 모드
    glob_eager: bool = false,
    /// import.meta.glob: named export 추출 (e.g., "setup")
    glob_import_name: ?[]const u8 = null,
};

/// import 바인딩 종류.
pub const ImportBindingKind = enum {
    default,
    named,
    namespace,
};

/// 파서가 수집하는 import 바인딩. bundler ImportBinding의 경량 버전.
pub const ScanImportBinding = struct {
    kind: ImportBindingKind,
    /// 이 모듈에서 사용하는 로컬 이름 (e.g. "bar" in `import { foo as bar }`)
    local_name: []const u8,
    /// 상대 모듈에서 export된 이름 (e.g. "foo", "default", "*")
    imported_name: []const u8,
    /// 로컬 바인딩의 소스 위치
    local_span: Span,
    /// 어떤 import 문에서 왔는지 (scan_import_records 인덱스)
    import_record_index: u32,
};

/// export 바인딩 종류.
pub const ExportBindingKind = enum {
    local,
    re_export,
    re_export_all,
};

/// 파서가 수집하는 export 바인딩. bundler ExportBinding의 경량 버전.
pub const ScanExportBinding = struct {
    /// 외부에 노출되는 이름 (e.g. "x", "default", "b" in `export { a as b }`)
    exported_name: []const u8,
    /// 모듈 내부 이름 (e.g. "x", "a")
    local_name: []const u8,
    /// 소스 위치
    local_span: Span,
    /// export 종류
    kind: ExportBindingKind,
    /// re-export 시 소스 모듈의 scan_import_records 인덱스
    import_record_index: ?u32 = null,
    /// #1328 Phase 3a: `export default <expr>` 구문에서 나온 바인딩인지.
    /// true = codegen이 로컬 `_default = <expr>` 할당을 emit한다.
    has_local_default_binding: bool = false,
};

/// CJS/ESM 감지 결과.
pub const ScanResult = struct {
    has_esm_syntax: bool = false,
    has_cjs_require: bool = false,
    has_module_exports: bool = false,
    has_exports_dot: bool = false,
};
