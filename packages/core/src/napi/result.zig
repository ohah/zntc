//! NAPI result object builders.

const zntc_lib = @import("zntc_lib");
const common = @import("common.zig");
const options_mod = @import("options.zig");

const c = common.c;
const bundler_mod = zntc_lib.bundler;
const LogFilterOptions = options_mod.LogFilterOptions;

pub fn buildResultToJS(env: c.napi_env, result: *const bundler_mod.BundleResult, log_opts: LogFilterOptions) c.napi_value {
    var js_result: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_result) != c.napi_ok) return null;

    var js_outputs: c.napi_value = undefined;
    _ = c.napi_create_array(env, &js_outputs);

    if (result.outputs) |outputs| {
        for (outputs, 0..) |out, i| {
            var js_file: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_file);

            var js_path: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, out.path.ptr, out.path.len, &js_path);
            _ = c.napi_set_named_property(env, js_file, "path", js_path);

            var js_text: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, out.contents.ptr, out.contents.len, &js_text);
            _ = c.napi_set_named_property(env, js_file, "text", js_text);

            var js_ids: c.napi_value = undefined;
            _ = c.napi_create_array(env, &js_ids);
            for (out.module_ids, 0..) |id, k| {
                var s: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, id.ptr, id.len, &s);
                _ = c.napi_set_element(env, js_ids, @intCast(k), s);
            }
            _ = c.napi_set_named_property(env, js_file, "moduleIds", js_ids);

            var js_exports: c.napi_value = undefined;
            _ = c.napi_create_array(env, &js_exports);
            for (out.exports, 0..) |ex, k| {
                var s: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, ex.ptr, ex.len, &s);
                _ = c.napi_set_element(env, js_exports, @intCast(k), s);
            }
            _ = c.napi_set_named_property(env, js_file, "exports", js_exports);

            var js_imports: c.napi_value = undefined;
            _ = c.napi_create_array(env, &js_imports);
            for (out.imports, 0..) |im, k| {
                var s: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, im.ptr, im.len, &s);
                _ = c.napi_set_element(env, js_imports, @intCast(k), s);
            }
            _ = c.napi_set_named_property(env, js_file, "imports", js_imports);

            _ = c.napi_set_element(env, js_outputs, @intCast(i), js_file);
        }
    } else {
        var js_file: c.napi_value = undefined;
        _ = c.napi_create_object(env, &js_file);

        var js_path: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, "bundle.js", "bundle.js".len, &js_path);
        _ = c.napi_set_named_property(env, js_file, "path", js_path);

        var js_text: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, result.output.ptr, result.output.len, &js_text);
        _ = c.napi_set_named_property(env, js_file, "text", js_text);

        _ = c.napi_set_element(env, js_outputs, 0, js_file);

        if (result.sourcemap) |sm| {
            var js_sm_file: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_sm_file);

            var js_sm_path: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, "bundle.js.map", "bundle.js.map".len, &js_sm_path);
            _ = c.napi_set_named_property(env, js_sm_file, "path", js_sm_path);

            var js_sm_text: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, sm.ptr, sm.len, &js_sm_text);
            _ = c.napi_set_named_property(env, js_sm_file, "text", js_sm_text);

            _ = c.napi_set_element(env, js_outputs, 1, js_sm_file);
        }
    }

    // asset_outputs (CSS bundle / worker chunks / file-loader 산출물 등) 도 outputFiles
    // 배열에 합쳐 JS 의 `writeOutputFiles` 가 dist 에 write 하도록 한다. native 만
    // 별도 storage 라 path/contents 외 metadata (module_ids/exports/imports) 는 없다.
    // (#3022 — vue/svelte SFC 의 `?vue&type=style&lang.css` sub-import 의 CSS bundle 이
    // dist 에 누락되던 회귀 해소.)
    if (result.asset_outputs) |assets| {
        var current_len: u32 = 0;
        _ = c.napi_get_array_length(env, js_outputs, &current_len);
        for (assets, 0..) |asset, i| {
            var js_asset: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_asset);

            var js_path: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, asset.path.ptr, asset.path.len, &js_path);
            _ = c.napi_set_named_property(env, js_asset, "path", js_path);

            var js_text: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, asset.contents.ptr, asset.contents.len, &js_text);
            _ = c.napi_set_named_property(env, js_asset, "text", js_text);

            _ = c.napi_set_element(env, js_outputs, current_len + @as(u32, @intCast(i)), js_asset);
        }
    }

    _ = c.napi_set_named_property(env, js_result, "outputFiles", js_outputs);

    var js_errors: c.napi_value = undefined;
    _ = c.napi_create_array(env, &js_errors);
    var js_warnings: c.napi_value = undefined;
    _ = c.napi_create_array(env, &js_warnings);

    const log_filter = log_opts.filter;
    const log_limit = log_opts.limit;

    var err_idx: u32 = 0;
    var warn_idx: u32 = 0;
    for (result.getDiagnostics()) |d| {
        const is_err = d.severity == .@"error";
        if (is_err and !log_filter.allow_errors) continue;
        if (!is_err and !log_filter.allow_warnings) continue;
        if (log_limit > 0) {
            if (is_err and err_idx >= log_limit) continue;
            if (!is_err and warn_idx >= log_limit) continue;
        }

        var js_diag: c.napi_value = undefined;
        _ = c.napi_create_object(env, &js_diag);

        var js_msg: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, d.message.ptr, d.message.len, &js_msg);
        _ = c.napi_set_named_property(env, js_diag, "text", js_msg);

        const code_name = @tagName(d.code);
        var js_code: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, code_name.ptr, code_name.len, &js_code);
        _ = c.napi_set_named_property(env, js_diag, "code", js_code);

        if (d.file_path.len > 0) {
            var js_loc: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_loc);
            var js_file_path: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, d.file_path.ptr, d.file_path.len, &js_file_path);
            _ = c.napi_set_named_property(env, js_loc, "file", js_file_path);
            _ = c.napi_set_named_property(env, js_diag, "location", js_loc);
        }

        if (is_err) {
            _ = c.napi_set_element(env, js_errors, err_idx, js_diag);
            err_idx += 1;
        } else {
            _ = c.napi_set_element(env, js_warnings, warn_idx, js_diag);
            warn_idx += 1;
        }
    }
    _ = c.napi_set_named_property(env, js_result, "errors", js_errors);
    _ = c.napi_set_named_property(env, js_result, "warnings", js_warnings);

    if (result.metafile_json) |mf| {
        var js_mf: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, mf.ptr, mf.len, &js_mf);
        _ = c.napi_set_named_property(env, js_result, "metafile", js_mf);
    }

    if (result.module_dev_codes) |codes| {
        var js_codes: c.napi_value = undefined;
        _ = c.napi_create_array_with_length(env, codes.len, &js_codes);
        for (codes, 0..) |mc, i| {
            var js_mc: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_mc);

            var js_id: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, mc.id.ptr, mc.id.len, &js_id);
            _ = c.napi_set_named_property(env, js_mc, "id", js_id);

            var js_code: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, mc.code.ptr, mc.code.len, &js_code);
            _ = c.napi_set_named_property(env, js_mc, "code", js_code);

            _ = c.napi_set_element(env, js_codes, @intCast(i), js_mc);
        }
        _ = c.napi_set_named_property(env, js_result, "moduleCodes", js_codes);
    }

    if (result.module_paths) |paths| {
        var js_paths: c.napi_value = undefined;
        _ = c.napi_create_array_with_length(env, paths.len, &js_paths);
        for (paths, 0..) |p, i| {
            var js_p: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, p.ptr, p.len, &js_p);
            _ = c.napi_set_element(env, js_paths, @intCast(i), js_p);
        }
        _ = c.napi_set_named_property(env, js_result, "modulePaths", js_paths);
    }

    return js_result;
}
