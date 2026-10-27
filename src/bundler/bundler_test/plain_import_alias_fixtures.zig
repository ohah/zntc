//! Exact plain-alias fixtures; candidate and baseline failures remain separate.
pub const Case = struct { name: []const u8, entry: []const u8, dep: []const u8, expected: []const u8, lazy: ?[]const u8 = null, barrel: ?[]const u8 = null };
pub const candidates = [_]Case{
    .{ .name = "original-full-async", .entry = "import Constructor,{publicName as title,값 as value,make as build} from \"./dep.mjs\"; import * as ns from \"./dep.mjs\"; async function run(){const {lazy}=await import(\"./lazy.mjs\");const object=build(\"key\"); console.log(JSON.stringify([title,value,new Constructor().read(),object.key,object.after,lazy,ns.publicName===title]));} run().catch(e=>{console.error(e);process.exitCode=1});", .dep = "export const publicName=\"public\"; export const 값=7; export default class 이름 { read(){return 값;} } export function make(k){return {[k]:2,after:3};} export const unused=\"dead-marker\";", .lazy = "import 이름 from \"./dep.mjs\"; export const lazy=new 이름().read();", .expected = "[\"public\",7,7,2,3,7,true]\n" },
    .{ .name = "direct-default-class", .entry = "import Constructor from \"./dep.mjs\";console.log(new Constructor().read());", .dep = "export default class 이름 {read(){return 7}}", .expected = "7\n" },
    .{ .name = "direct-default-function", .entry = "import read from \"./dep.mjs\";console.log(read());", .dep = "export default function 읽기(){return 7}", .expected = "7\n" },
    .{ .name = "parenthesized-new", .entry = "import Constructor from \"./dep.mjs\";console.log(new (Constructor)().read());", .dep = "export default class 이름 {read(){return 7}}", .expected = "7\n" },
    .{ .name = "closure-new", .entry = "import Constructor from \"./dep.mjs\";const make=()=>new Constructor();console.log(make().read());", .dep = "export default class 이름 {read(){return 7}}", .expected = "7\n" },
    .{ .name = "class-heritage", .entry = "import Constructor from \"./dep.mjs\";class Child extends Constructor{}console.log(new Child().read());", .dep = "export default class 이름 {read(){return 7}}", .expected = "7\n" },
    .{ .name = "named-unicode-class", .entry = "import {이름 as Constructor} from \"./dep.mjs\";console.log(new Constructor().read());", .dep = "export class 이름{read(){return 7}}", .expected = "7\n" },
    .{ .name = "reexport-default", .entry = "import Constructor from \"./barrel.mjs\";console.log(new Constructor().read());", .dep = "export default class 이름 {read(){return 7}}", .expected = "7\n", .barrel = "export {default} from \"./dep.mjs\";" },
    .{ .name = "named-object-value", .entry = "import {데이터 as value} from \"./dep.mjs\";console.log(value.read);", .dep = "export const 데이터={read:7};", .expected = "7\n" },
    .{ .name = "tagged-template", .entry = "import {태그 as tag} from \"./dep.mjs\";console.log(tag`value`);", .dep = "export function 태그(){return 7}", .expected = "7\n" },
};
pub const controls = [_]Case{
    .{ .name = "ASCII-provider-alias", .entry = "import Constructor from \"./dep.mjs\";console.log(new Constructor().read());", .dep = "export default class Provider{read(){return 7}}", .expected = "7\n" },
    .{ .name = "Unicode-same-local", .entry = "import 이름 from \"./dep.mjs\";console.log(new 이름().read());", .dep = "export default class 이름{read(){return 7}}", .expected = "7\n" },
    .{ .name = "ASCII-named-alias", .entry = "import {Provider as Constructor} from \"./dep.mjs\";console.log(new Constructor().read());", .dep = "export class Provider{read(){return 7}}", .expected = "7\n" },
    .{ .name = "same-spelling-shadow", .entry = "import Constructor from \"./dep.mjs\";function keep(Constructor){return Constructor}console.log(JSON.stringify([new Constructor().read(),keep(2)]));", .dep = "export default class Provider{read(){return 7}}", .expected = "[7,2]\n" },
};

pub const property_source_controls = [_]Case{
    .{ .name = "escaped-provider-binding", .entry = "import Constructor from \"./dep.mjs\";console.log(new Constructor().read());", .dep = "export default class \\uC774\\uB984{read(){return 7}}", .expected = "7\n" },
    .{ .name = "mutable-Unicode-key", .entry = "import {값 as read,bump} from \"./dep.mjs\";bump();console.log(read);", .dep = "export let 값=6;export function bump(){값++}", .expected = "7\n" },
};
