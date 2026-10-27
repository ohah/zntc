const Tag = enum {
    none,
    identifier_reference,
    assignment_target_identifier,
    binding_identifier,
    jsx_identifier,
};
const Node = struct { tag: Tag };
const global_identifier_tag: Tag = .identifier_reference;
const global_identifier_tag_alias = global_identifier_tag;
const Kind = enum { tag, other };
const Result = enum { identifier_reference, other };

fn switchProbe(value: Kind) Result {
    return switch (value) {
        .tag => .identifier_reference,
        else => .other,
    };
}

fn probe0() Node {
    return .{
        .tag = .identifier_reference,
    };
}
const after_function_identifier_tag: Tag = .binding_identifier;
fn probe1() Node {
    return .{
        .tag = if (true)
            .assignment_target_identifier
        else
            .none,
    };
}
fn probe2() Node {
    return .{
        .tag = if (false) .none else .binding_identifier,
    };
}
fn probe3() Node {
    return .{
        .tag = if (true) .jsx_identifier else .none,
    };
}
fn probe4() Node {
    return .{
        .tag = switch (0) {
            0 => .identifier_reference,
            else => .none,
        },
    };
}
fn probe5() Node {
    return .{
        .tag = blk: {
            break :blk .assignment_target_identifier;
        },
    };
}
fn choose(first: bool, second: bool) bool {
    return first and !second;
}
fn probe6() Node {
    return .{
        .tag = if (choose(true, false)) .binding_identifier else .none,
    };
}
fn probe7() Node {
    return .{
        .tag = if (choose(false, true)) .none else .jsx_identifier,
    };
}
fn probe8() Node {
    return .{
        .tag = if (true) .none else .assignment_target_identifier,
    };
}
fn probe9() Node {
    return .{ .tag = .identifier_reference };
}
fn makeBindingIdentifier(_: Tag) void {}
fn probe10() void {
    makeBindingIdentifier(.identifier_reference);
}
fn probe11() Node {
    const identifier_tag: Tag = .identifier_reference;
    return .{ .tag = identifier_tag };
}
fn probe12() Node {
    const identifier_tag: Tag = if (true) .none else .binding_identifier;
    return .{ .tag = identifier_tag };
}
fn probe13() Node {
    const first_tag: Tag = .jsx_identifier;
    const second_tag = first_tag;
    return .{ .tag = second_tag };
}
fn probe14() Node {
    const identifier_tag: Tag = switch (1) {
        0 => .none,
        else => .identifier_reference,
    };
    return .{ .tag = identifier_tag };
}
fn probe15() Node {
    const identifier_tag: Tag = blk: {
        break :blk .assignment_target_identifier;
    };
    return .{ .tag = identifier_tag };
}
fn probe16() Node {
    var identifier_tag: Tag = .binding_identifier;
    identifier_tag = .binding_identifier;
    return .{ .tag = identifier_tag };
}
fn probe17() Node {
    const identifier_tag: Tag = if (true) .none else if (false) .none else .jsx_identifier;
    return .{ .tag = identifier_tag };
}
fn probe18() Node {
    const first_tag: Tag = .identifier_reference;
    const second_tag: Tag = first_tag;
    const third_tag = second_tag;
    return .{ .tag = third_tag };
}
fn probe19() Node {
    const first_tag: Tag = if (true) .binding_identifier else .none;
    const second_tag = first_tag;
    return .{ .tag = second_tag };
}
fn probe20() Node {
    const identifier_tag: Tag = if (false) .none else .assignment_target_identifier;
    return .{ .tag = identifier_tag };
}
fn probe21() Node {
    return .{ .tag = global_identifier_tag };
}
fn probe22() Node {
    const local_identifier_tag_alias = global_identifier_tag_alias;
    return .{ .tag = local_identifier_tag_alias };
}
fn probe23() Node {
    return .{ .tag = after_function_identifier_tag };
}

test "all direct constructors are compileable Zig mutations" {
    _ = .{ probe0(), probe1(), probe2(), probe3(), probe4(), probe5(), probe6(), probe7(), probe8(), probe9(), probe11(), probe12(), probe13(), probe14(), probe15(), probe16(), probe17(), probe18(), probe19(), probe20(), probe21(), probe22(), probe23() };
    probe10();
}

test "constructor examples inside test blocks are ignored" {
    const fixture = .{ .tag = .identifier_reference };
    _ = fixture;
}
