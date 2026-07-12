---
title: Error codes reference
description: Complete list of ZNTC error codes
---

ZNTC assigns a unique code to every diagnostic. Click a code for details and a reproduction snippet.


## Target/Compatibility

| Code | Message |
|------|--------|
| [`ZNTC0001`](/zntc/en/reference/errors/zntc0001) | Top-level await is not available in the configured target environment |
| [`ZNTC0002`](/zntc/en/reference/errors/zntc0002) | Top-level await requires ESM output format |
| [`ZNTC0003`](/zntc/en/reference/errors/zntc0003) | Code splitting requires ESM output format |
| [`ZNTC0004`](/zntc/en/reference/errors/zntc0004) | Entry path is empty or not found |
| [`ZNTC0005`](/zntc/en/reference/errors/zntc0005) | preserveModules requires ESM output format |

## Bundler: Import/Export

| Code | Message |
|------|--------|
| [`ZNTC0100`](/zntc/en/reference/errors/zntc0100) | Could not resolve import |
| [`ZNTC0101`](/zntc/en/reference/errors/zntc0101) | Export not found in module |
| [`ZNTC0102`](/zntc/en/reference/errors/zntc0102) | Circular dependency detected |
| [`ZNTC0103`](/zntc/en/reference/errors/zntc0103) | Module resolution failed |
| [`ZNTC0104`](/zntc/en/reference/errors/zntc0104) | Re-export references the module itself (self-cycle) |
| [`ZNTC0105`](/zntc/en/reference/errors/zntc0105) | Ambiguous import: a name is exported by multiple modules via 'export *' |
| [`ZNTC0106`](/zntc/en/reference/errors/zntc0106) | Output exports conflict with the selected module format |

## Bundler: File/Loader

| Code | Message |
|------|--------|
| [`ZNTC0200`](/zntc/en/reference/errors/zntc0200) | Failed to read file |
| [`ZNTC0201`](/zntc/en/reference/errors/zntc0201) | Failed to parse JSON |
| [`ZNTC0202`](/zntc/en/reference/errors/zntc0202) | No loader is configured for this file type |
| [`ZNTC0203`](/zntc/en/reference/errors/zntc0203) | Invalid require.context() call |
| [`ZNTC0204`](/zntc/en/reference/errors/zntc0204) | require.context() requires a configured handler |
| [`ZNTC0205`](/zntc/en/reference/errors/zntc0205) | Bundler plugin error |

## Parser: Import/Export

| Code | Message |
|------|--------|
| [`ZNTC0300`](/zntc/en/reference/errors/zntc0300) | 'import' declaration is only allowed in module code |
| [`ZNTC0301`](/zntc/en/reference/errors/zntc0301) | 'import' declaration must be at the top level |
| [`ZNTC0302`](/zntc/en/reference/errors/zntc0302) | 'import defer/source' requires a binding |
| [`ZNTC0303`](/zntc/en/reference/errors/zntc0303) | String literal in import specifier requires 'as' binding |
| [`ZNTC0304`](/zntc/en/reference/errors/zntc0304) | Duplicate import attribute key |
| [`ZNTC0305`](/zntc/en/reference/errors/zntc0305) | 'export' declaration is only allowed in module code |
| [`ZNTC0306`](/zntc/en/reference/errors/zntc0306) | 'export' declaration must be at the top level |
| [`ZNTC0307`](/zntc/en/reference/errors/zntc0307) | String literal cannot be used as local binding in export |
| [`ZNTC0308`](/zntc/en/reference/errors/zntc0308) | Module source string expected |
| [`ZNTC0309`](/zntc/en/reference/errors/zntc0309) | 'export' is not allowed in statement position |
| [`ZNTC0310`](/zntc/en/reference/errors/zntc0310) | 'import' is not allowed in statement position |
| [`ZNTC0311`](/zntc/en/reference/errors/zntc0311) | 'import' cannot be used with 'new' |
| [`ZNTC0312`](/zntc/en/reference/errors/zntc0312) | 'import.meta' is only allowed in module code |
| [`ZNTC0313`](/zntc/en/reference/errors/zntc0313) | Expected 'import.meta', 'import.source', or 'import.defer' |
| [`ZNTC0314`](/zntc/en/reference/errors/zntc0314) | 'import.source'/'import.defer' requires arguments |

## Parser: Declaration/Class

| Code | Message |
|------|--------|
| [`ZNTC0400`](/zntc/en/reference/errors/zntc0400) | Anonymous function declaration cannot be invoked |
| [`ZNTC0401`](/zntc/en/reference/errors/zntc0401) | Function declaration is not allowed in statement position |
| [`ZNTC0402`](/zntc/en/reference/errors/zntc0402) | Function declaration is not allowed in statement position in strict mode |
| [`ZNTC0403`](/zntc/en/reference/errors/zntc0403) | Generator declaration is not allowed in statement position |
| [`ZNTC0404`](/zntc/en/reference/errors/zntc0404) | Async function declaration is not allowed in statement position |
| [`ZNTC0405`](/zntc/en/reference/errors/zntc0405) | Class declaration is not allowed in statement position |
| [`ZNTC0406`](/zntc/en/reference/errors/zntc0406) | Class constructor cannot be a getter, setter, generator, or async |
| [`ZNTC0407`](/zntc/en/reference/errors/zntc0407) | Class member cannot be named '#constructor' |
| [`ZNTC0408`](/zntc/en/reference/errors/zntc0408) | Class field cannot be named 'constructor' |
| [`ZNTC0409`](/zntc/en/reference/errors/zntc0409) | Static class field cannot be named 'prototype' |
| [`ZNTC0410`](/zntc/en/reference/errors/zntc0410) | Static class method cannot be named 'prototype' |
| [`ZNTC0411`](/zntc/en/reference/errors/zntc0411) | Class expected after decorator |
| [`ZNTC0412`](/zntc/en/reference/errors/zntc0412) | Class or export expected after decorator |
| [`ZNTC0415`](/zntc/en/reference/errors/zntc0415) | Decorators are not valid on class static blocks |
| [`ZNTC0413`](/zntc/en/reference/errors/zntc0413) | Labelled function declaration is not allowed in loop body |
| [`ZNTC0414`](/zntc/en/reference/errors/zntc0414) | Lexical declaration is not allowed in statement position |

## Parser: Binding/Identifier

| Code | Message |
|------|--------|
| [`ZNTC0500`](/zntc/en/reference/errors/zntc0500) | Identifier expected |
| [`ZNTC0501`](/zntc/en/reference/errors/zntc0501) | Binding pattern expected |
| [`ZNTC0502`](/zntc/en/reference/errors/zntc0502) | Escaped reserved word cannot be used as identifier |
| [`ZNTC0503`](/zntc/en/reference/errors/zntc0503) | Escaped reserved word cannot be used as identifier in strict mode |
| [`ZNTC0504`](/zntc/en/reference/errors/zntc0504) | Reserved word cannot be used as identifier |
| [`ZNTC0505`](/zntc/en/reference/errors/zntc0505) | Reserved word in strict mode cannot be used as identifier |
| [`ZNTC0506`](/zntc/en/reference/errors/zntc0506) | Keywords cannot contain escape characters |
| [`ZNTC0507`](/zntc/en/reference/errors/zntc0507) | 'let' is not allowed as variable name in lexical declaration |
| [`ZNTC0508`](/zntc/en/reference/errors/zntc0508) | Const declarations must be initialized |
| [`ZNTC0509`](/zntc/en/reference/errors/zntc0509) | 'async' is not allowed as identifier in for-of left-hand side |
| [`ZNTC0510`](/zntc/en/reference/errors/zntc0510) | 'let' is not allowed as identifier in for-of left-hand side |
| [`ZNTC0511`](/zntc/en/reference/errors/zntc0511) | Only a single variable declaration is allowed in a for-in/for-of statement |
| [`ZNTC0512`](/zntc/en/reference/errors/zntc0512) | For-in/for-of loop variable declaration may not have an initializer |
| [`ZNTC0513`](/zntc/en/reference/errors/zntc0513) | Rest element must be last element |
| [`ZNTC0514`](/zntc/en/reference/errors/zntc0514) | Rest element may not have a trailing comma |
| [`ZNTC0515`](/zntc/en/reference/errors/zntc0515) | Duplicate parameter name |
| [`ZNTC0516`](/zntc/en/reference/errors/zntc0516) | Private name is not allowed in destructuring pattern |
| [`ZNTC0517`](/zntc/en/reference/errors/zntc0517) | Invalid assignment target |
| [`ZNTC0518`](/zntc/en/reference/errors/zntc0518) | Assignment to 'eval' or 'arguments' is not allowed in strict mode |

## Parser: Expression/Operator

| Code | Message |
|------|--------|
| [`ZNTC0600`](/zntc/en/reference/errors/zntc0600) | Expression expected |
| [`ZNTC0601`](/zntc/en/reference/errors/zntc0601) | Unary expression cannot be the left operand of '**' |
| [`ZNTC0602`](/zntc/en/reference/errors/zntc0602) | Cannot mix '??' with '&&' or '||' without parentheses |
| [`ZNTC0603`](/zntc/en/reference/errors/zntc0603) | Private name is not valid outside of 'in' expression |
| [`ZNTC0604`](/zntc/en/reference/errors/zntc0604) | Private name is not valid as right-hand side of 'in' expression |
| [`ZNTC0605`](/zntc/en/reference/errors/zntc0605) | Private fields cannot be deleted |
| [`ZNTC0606`](/zntc/en/reference/errors/zntc0606) | Private field access on super is not allowed |
| [`ZNTC0620`](/zntc/en/reference/errors/zntc0620) | 'super' is not allowed outside of a method |
| [`ZNTC0621`](/zntc/en/reference/errors/zntc0621) | 'super()' is only allowed in a class constructor |
| [`ZNTC0622`](/zntc/en/reference/errors/zntc0622) | 'super' cannot be used as the base of an optional chain |
| [`ZNTC0623`](/zntc/en/reference/errors/zntc0623) | Invalid optional chain in 'new' expression |
| [`ZNTC0607`](/zntc/en/reference/errors/zntc0607) | Tagged template cannot be used in optional chain |
| [`ZNTC0608`](/zntc/en/reference/errors/zntc0608) | Property key expected |
| [`ZNTC0609`](/zntc/en/reference/errors/zntc0609) | Expected ':' after property key |
| [`ZNTC0610`](/zntc/en/reference/errors/zntc0610) | Invalid shorthand property initializer |
| [`ZNTC0611`](/zntc/en/reference/errors/zntc0611) | Reserved word cannot be used as shorthand property |
| [`ZNTC0612`](/zntc/en/reference/errors/zntc0612) | Reserved word in strict mode cannot be used as shorthand property |
| [`ZNTC0613`](/zntc/en/reference/errors/zntc0613) | 'yield' cannot be used as shorthand property in generator |
| [`ZNTC0614`](/zntc/en/reference/errors/zntc0614) | 'await' cannot be used as shorthand property in async/module |
| [`ZNTC0615`](/zntc/en/reference/errors/zntc0615) | Private identifier is not allowed as object property key |
| [`ZNTC0616`](/zntc/en/reference/errors/zntc0616) | 'arguments' is not allowed in class field initializer |
| [`ZNTC0617`](/zntc/en/reference/errors/zntc0617) | 'arguments' is not allowed in class static initializer |
| [`ZNTC0618`](/zntc/en/reference/errors/zntc0618) | String literal contains lone surrogate |
| [`ZNTC0619`](/zntc/en/reference/errors/zntc0619) | 'new.target' is not allowed outside of functions |

## Parser: Statement/Control Flow

| Code | Message |
|------|--------|
| [`ZNTC0700`](/zntc/en/reference/errors/zntc0700) | 'return' outside of function |
| [`ZNTC0701`](/zntc/en/reference/errors/zntc0701) | 'break' outside of loop or switch |
| [`ZNTC0702`](/zntc/en/reference/errors/zntc0702) | 'continue' outside of loop |
| [`ZNTC0703`](/zntc/en/reference/errors/zntc0703) | Only one default clause is allowed in a switch statement |
| [`ZNTC0704`](/zntc/en/reference/errors/zntc0704) | Case or default expected |
| [`ZNTC0705`](/zntc/en/reference/errors/zntc0705) | Catch or finally expected |
| [`ZNTC0706`](/zntc/en/reference/errors/zntc0706) | No line break is allowed after 'throw' |
| [`ZNTC0707`](/zntc/en/reference/errors/zntc0707) | Escaped reserved word cannot be used as label |
| [`ZNTC0708`](/zntc/en/reference/errors/zntc0708) | Escaped reserved word cannot be used as label in strict mode |
| [`ZNTC0709`](/zntc/en/reference/errors/zntc0709) | Reserved word in strict mode cannot be used as label |

## Parser: Strict Mode

| Code | Message |
|------|--------|
| [`ZNTC0800`](/zntc/en/reference/errors/zntc0800) | 'with' is not allowed in strict mode |
| [`ZNTC0801`](/zntc/en/reference/errors/zntc0801) | Octal literals are not allowed in strict mode |
| [`ZNTC0802`](/zntc/en/reference/errors/zntc0802) | Octal escape sequences are not allowed in strict mode |
| [`ZNTC0803`](/zntc/en/reference/errors/zntc0803) | Deleting an identifier is not allowed in strict mode |
| [`ZNTC0804`](/zntc/en/reference/errors/zntc0804) | \"use strict\" not allowed in function with non-simple parameters |
| [`ZNTC0805`](/zntc/en/reference/errors/zntc0805) | Cannot assign to or delete an imported binding |

## Parser: Await/Yield/JSX/TS

| Code | Message |
|------|--------|
| [`ZNTC0900`](/zntc/en/reference/errors/zntc0900) | 'await' cannot be used as identifier in this context |
| [`ZNTC0901`](/zntc/en/reference/errors/zntc0901) | 'await' expression is not allowed in formal parameters |
| [`ZNTC0902`](/zntc/en/reference/errors/zntc0902) | 'await' is not allowed in class static initializer |
| [`ZNTC0903`](/zntc/en/reference/errors/zntc0903) | 'await' is not allowed in non-async function in module code |
| [`ZNTC0904`](/zntc/en/reference/errors/zntc0904) | 'await' is not allowed in arrow function parameters |
| [`ZNTC0905`](/zntc/en/reference/errors/zntc0905) | 'await' is not allowed in async arrow function parameters |
| [`ZNTC0906`](/zntc/en/reference/errors/zntc0906) | 'yield' expression is not allowed in formal parameters |
| [`ZNTC0907`](/zntc/en/reference/errors/zntc0907) | 'yield' is not allowed in arrow function parameters |
| [`ZNTC0908`](/zntc/en/reference/errors/zntc0908) | Invalid escape sequence in template literal |
| [`ZNTC0909`](/zntc/en/reference/errors/zntc0909) | Expected template continuation |
| [`ZNTC0910`](/zntc/en/reference/errors/zntc0910) | JSX tag name expected |
| [`ZNTC0911`](/zntc/en/reference/errors/zntc0911) | Spread expected |
| [`ZNTC0912`](/zntc/en/reference/errors/zntc0912) | Type expected |
| [`ZNTC0913`](/zntc/en/reference/errors/zntc0913) | Expected 'in' in mapped type |
| [`ZNTC0914`](/zntc/en/reference/errors/zntc0914) | Expected 'type' after 'opaque' |
| [`ZNTC0915`](/zntc/en/reference/errors/zntc0915) | Modifiers cannot appear on index signature parameters |
| [`ZNTC0916`](/zntc/en/reference/errors/zntc0916) | An index signature parameter cannot have a question mark |
| [`ZNTC0917`](/zntc/en/reference/errors/zntc0917) | 'yield' is not allowed outside generator function |
| [`ZNTC0918`](/zntc/en/reference/errors/zntc0918) | TypeScript syntax is not allowed in JavaScript source |

## Semantic: Redeclaration

| Code | Message |
|------|--------|
| [`ZNTC1000`](/zntc/en/reference/errors/zntc1000) | Identifier has already been declared |
| [`ZNTC1001`](/zntc/en/reference/errors/zntc1001) | Cannot be used as a binding identifier in strict mode |

## Semantic: Private Member

| Code | Message |
|------|--------|
| [`ZNTC1100`](/zntc/en/reference/errors/zntc1100) | Private field has already been declared |
| [`ZNTC1101`](/zntc/en/reference/errors/zntc1101) | Private field must be declared in an enclosing class |

## Semantic: Export/Label

| Code | Message |
|------|--------|
| [`ZNTC1200`](/zntc/en/reference/errors/zntc1200) | Duplicate export name |
| [`ZNTC1201`](/zntc/en/reference/errors/zntc1201) | Export is not defined |
| [`ZNTC1202`](/zntc/en/reference/errors/zntc1202) | Label has already been declared |
| [`ZNTC1203`](/zntc/en/reference/errors/zntc1203) | Cannot continue to non-loop label |
| [`ZNTC1204`](/zntc/en/reference/errors/zntc1204) | Undefined label |

## Semantic: Class/Other

| Code | Message |
|------|--------|
| [`ZNTC1300`](/zntc/en/reference/errors/zntc1300) | A class may only have one constructor |
| [`ZNTC1301`](/zntc/en/reference/errors/zntc1301) | Property name __proto__ appears more than once in object literal |
| [`ZNTC1302`](/zntc/en/reference/errors/zntc1302) | Getter must not have any formal parameters |
| [`ZNTC1303`](/zntc/en/reference/errors/zntc1303) | Setter must have exactly one formal parameter |
| [`ZNTC1400`](/zntc/en/reference/errors/zntc1400) | Type reference is not defined in the same file |
| [`ZNTC1401`](/zntc/en/reference/errors/zntc1401) | Prop type is not supported by codegen |
| [`ZNTC1402`](/zntc/en/reference/errors/zntc1402) | NativeProps body is not an object literal or known wrapper |
| [`ZNTC1403`](/zntc/en/reference/errors/zntc1403) | Duplicate component name in schema |
| [`ZNTC1404`](/zntc/en/reference/errors/zntc1404) | Inheritance / intersection chain exceeds depth limit |

## Transformer

| Code | Message |
|------|--------|
| [`ZNTC1500`](/zntc/en/reference/errors/zntc1500) | @jsx / @jsxFrag pragma ignored under the automatic JSX runtime |
| [`ZNTC1501`](/zntc/en/reference/errors/zntc1501) | Regular expression inline modifier group is an ES2025 feature not supported by the target |
