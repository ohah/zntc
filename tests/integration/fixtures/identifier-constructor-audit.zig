const Tag = enum {
    none,
    identifier_reference,
    assignment_target_identifier,
    binding_identifier,
    jsx_identifier,
};
const Node = struct { tag: Tag };
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

test "all direct constructors are compileable Zig mutations" {
    _ = .{ probe0(), probe1(), probe2(), probe3(), probe4(), probe5(), probe6(), probe7(), probe8(), probe9() };
    probe10();
}

test "constructor examples inside test blocks are ignored" {
    const fixture = .{ .tag = .identifier_reference };
    _ = fixture;
}
