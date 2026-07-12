---
title: 에러 코드 레퍼런스
description: ZNTC 에러 코드 전체 목록
---

ZNTC는 모든 에러에 고유 코드를 부여합니다. 에러 코드를 클릭하면 상세 설명과 재현 코드를 볼 수 있습니다.


## 타겟/호환성

| 코드 | 메시지 |
|------|--------|
| [`ZNTC0001`](/zntc/reference/errors/zntc0001) | Top-level await is not available in the configured target environment |
| [`ZNTC0002`](/zntc/reference/errors/zntc0002) | Top-level await requires ESM output format |
| [`ZNTC0003`](/zntc/reference/errors/zntc0003) | Code splitting requires ESM output format |
| [`ZNTC0004`](/zntc/reference/errors/zntc0004) | Entry path is empty or not found |
| [`ZNTC0005`](/zntc/reference/errors/zntc0005) | preserveModules requires ESM output format |

## 번들러: import/export

| 코드 | 메시지 |
|------|--------|
| [`ZNTC0100`](/zntc/reference/errors/zntc0100) | Could not resolve import |
| [`ZNTC0101`](/zntc/reference/errors/zntc0101) | Export not found in module |
| [`ZNTC0102`](/zntc/reference/errors/zntc0102) | Circular dependency detected |
| [`ZNTC0103`](/zntc/reference/errors/zntc0103) | Module resolution failed |
| [`ZNTC0104`](/zntc/reference/errors/zntc0104) | Re-export references the module itself (self-cycle) |
| [`ZNTC0105`](/zntc/reference/errors/zntc0105) | Ambiguous import: a name is exported by multiple modules via 'export *' |
| [`ZNTC0106`](/zntc/reference/errors/zntc0106) | Output exports conflict with the selected module format |

## 번들러: 파일/로더

| 코드 | 메시지 |
|------|--------|
| [`ZNTC0200`](/zntc/reference/errors/zntc0200) | Failed to read file |
| [`ZNTC0201`](/zntc/reference/errors/zntc0201) | Failed to parse JSON |
| [`ZNTC0202`](/zntc/reference/errors/zntc0202) | No loader is configured for this file type |
| [`ZNTC0203`](/zntc/reference/errors/zntc0203) | Invalid require.context() call |
| [`ZNTC0204`](/zntc/reference/errors/zntc0204) | require.context() requires a configured handler |
| [`ZNTC0205`](/zntc/reference/errors/zntc0205) | Bundler plugin error |

## 파서: import/export

| 코드 | 메시지 |
|------|--------|
| [`ZNTC0300`](/zntc/reference/errors/zntc0300) | 'import' declaration is only allowed in module code |
| [`ZNTC0301`](/zntc/reference/errors/zntc0301) | 'import' declaration must be at the top level |
| [`ZNTC0302`](/zntc/reference/errors/zntc0302) | 'import defer/source' requires a binding |
| [`ZNTC0303`](/zntc/reference/errors/zntc0303) | String literal in import specifier requires 'as' binding |
| [`ZNTC0304`](/zntc/reference/errors/zntc0304) | Duplicate import attribute key |
| [`ZNTC0305`](/zntc/reference/errors/zntc0305) | 'export' declaration is only allowed in module code |
| [`ZNTC0306`](/zntc/reference/errors/zntc0306) | 'export' declaration must be at the top level |
| [`ZNTC0307`](/zntc/reference/errors/zntc0307) | String literal cannot be used as local binding in export |
| [`ZNTC0308`](/zntc/reference/errors/zntc0308) | Module source string expected |
| [`ZNTC0309`](/zntc/reference/errors/zntc0309) | 'export' is not allowed in statement position |
| [`ZNTC0310`](/zntc/reference/errors/zntc0310) | 'import' is not allowed in statement position |
| [`ZNTC0311`](/zntc/reference/errors/zntc0311) | 'import' cannot be used with 'new' |
| [`ZNTC0312`](/zntc/reference/errors/zntc0312) | 'import.meta' is only allowed in module code |
| [`ZNTC0313`](/zntc/reference/errors/zntc0313) | Expected 'import.meta', 'import.source', or 'import.defer' |
| [`ZNTC0314`](/zntc/reference/errors/zntc0314) | 'import.source'/'import.defer' requires arguments |

## 파서: 선언/클래스

| 코드 | 메시지 |
|------|--------|
| [`ZNTC0400`](/zntc/reference/errors/zntc0400) | Anonymous function declaration cannot be invoked |
| [`ZNTC0401`](/zntc/reference/errors/zntc0401) | Function declaration is not allowed in statement position |
| [`ZNTC0402`](/zntc/reference/errors/zntc0402) | Function declaration is not allowed in statement position in strict mode |
| [`ZNTC0403`](/zntc/reference/errors/zntc0403) | Generator declaration is not allowed in statement position |
| [`ZNTC0404`](/zntc/reference/errors/zntc0404) | Async function declaration is not allowed in statement position |
| [`ZNTC0405`](/zntc/reference/errors/zntc0405) | Class declaration is not allowed in statement position |
| [`ZNTC0406`](/zntc/reference/errors/zntc0406) | Class constructor cannot be a getter, setter, generator, or async |
| [`ZNTC0407`](/zntc/reference/errors/zntc0407) | Class member cannot be named '#constructor' |
| [`ZNTC0408`](/zntc/reference/errors/zntc0408) | Class field cannot be named 'constructor' |
| [`ZNTC0409`](/zntc/reference/errors/zntc0409) | Static class field cannot be named 'prototype' |
| [`ZNTC0410`](/zntc/reference/errors/zntc0410) | Static class method cannot be named 'prototype' |
| [`ZNTC0411`](/zntc/reference/errors/zntc0411) | Class expected after decorator |
| [`ZNTC0412`](/zntc/reference/errors/zntc0412) | Class or export expected after decorator |
| [`ZNTC0415`](/zntc/reference/errors/zntc0415) | Decorators are not valid on class static blocks |
| [`ZNTC0413`](/zntc/reference/errors/zntc0413) | Labelled function declaration is not allowed in loop body |
| [`ZNTC0414`](/zntc/reference/errors/zntc0414) | Lexical declaration is not allowed in statement position |

## 파서: 바인딩/식별자

| 코드 | 메시지 |
|------|--------|
| [`ZNTC0500`](/zntc/reference/errors/zntc0500) | Identifier expected |
| [`ZNTC0501`](/zntc/reference/errors/zntc0501) | Binding pattern expected |
| [`ZNTC0502`](/zntc/reference/errors/zntc0502) | Escaped reserved word cannot be used as identifier |
| [`ZNTC0503`](/zntc/reference/errors/zntc0503) | Escaped reserved word cannot be used as identifier in strict mode |
| [`ZNTC0504`](/zntc/reference/errors/zntc0504) | Reserved word cannot be used as identifier |
| [`ZNTC0505`](/zntc/reference/errors/zntc0505) | Reserved word in strict mode cannot be used as identifier |
| [`ZNTC0506`](/zntc/reference/errors/zntc0506) | Keywords cannot contain escape characters |
| [`ZNTC0507`](/zntc/reference/errors/zntc0507) | 'let' is not allowed as variable name in lexical declaration |
| [`ZNTC0508`](/zntc/reference/errors/zntc0508) | Const declarations must be initialized |
| [`ZNTC0509`](/zntc/reference/errors/zntc0509) | 'async' is not allowed as identifier in for-of left-hand side |
| [`ZNTC0510`](/zntc/reference/errors/zntc0510) | 'let' is not allowed as identifier in for-of left-hand side |
| [`ZNTC0511`](/zntc/reference/errors/zntc0511) | Only a single variable declaration is allowed in a for-in/for-of statement |
| [`ZNTC0512`](/zntc/reference/errors/zntc0512) | For-in/for-of loop variable declaration may not have an initializer |
| [`ZNTC0513`](/zntc/reference/errors/zntc0513) | Rest element must be last element |
| [`ZNTC0514`](/zntc/reference/errors/zntc0514) | Rest element may not have a trailing comma |
| [`ZNTC0515`](/zntc/reference/errors/zntc0515) | Duplicate parameter name |
| [`ZNTC0516`](/zntc/reference/errors/zntc0516) | Private name is not allowed in destructuring pattern |
| [`ZNTC0517`](/zntc/reference/errors/zntc0517) | Invalid assignment target |
| [`ZNTC0518`](/zntc/reference/errors/zntc0518) | Assignment to 'eval' or 'arguments' is not allowed in strict mode |

## 파서: 식/연산자

| 코드 | 메시지 |
|------|--------|
| [`ZNTC0600`](/zntc/reference/errors/zntc0600) | Expression expected |
| [`ZNTC0601`](/zntc/reference/errors/zntc0601) | Unary expression cannot be the left operand of '**' |
| [`ZNTC0602`](/zntc/reference/errors/zntc0602) | Cannot mix '??' with '&&' or '||' without parentheses |
| [`ZNTC0603`](/zntc/reference/errors/zntc0603) | Private name is not valid outside of 'in' expression |
| [`ZNTC0604`](/zntc/reference/errors/zntc0604) | Private name is not valid as right-hand side of 'in' expression |
| [`ZNTC0605`](/zntc/reference/errors/zntc0605) | Private fields cannot be deleted |
| [`ZNTC0606`](/zntc/reference/errors/zntc0606) | Private field access on super is not allowed |
| [`ZNTC0620`](/zntc/reference/errors/zntc0620) | 'super' is not allowed outside of a method |
| [`ZNTC0621`](/zntc/reference/errors/zntc0621) | 'super()' is only allowed in a class constructor |
| [`ZNTC0622`](/zntc/reference/errors/zntc0622) | 'super' cannot be used as the base of an optional chain |
| [`ZNTC0623`](/zntc/reference/errors/zntc0623) | Invalid optional chain in 'new' expression |
| [`ZNTC0607`](/zntc/reference/errors/zntc0607) | Tagged template cannot be used in optional chain |
| [`ZNTC0608`](/zntc/reference/errors/zntc0608) | Property key expected |
| [`ZNTC0609`](/zntc/reference/errors/zntc0609) | Expected ':' after property key |
| [`ZNTC0610`](/zntc/reference/errors/zntc0610) | Invalid shorthand property initializer |
| [`ZNTC0611`](/zntc/reference/errors/zntc0611) | Reserved word cannot be used as shorthand property |
| [`ZNTC0612`](/zntc/reference/errors/zntc0612) | Reserved word in strict mode cannot be used as shorthand property |
| [`ZNTC0613`](/zntc/reference/errors/zntc0613) | 'yield' cannot be used as shorthand property in generator |
| [`ZNTC0614`](/zntc/reference/errors/zntc0614) | 'await' cannot be used as shorthand property in async/module |
| [`ZNTC0615`](/zntc/reference/errors/zntc0615) | Private identifier is not allowed as object property key |
| [`ZNTC0616`](/zntc/reference/errors/zntc0616) | 'arguments' is not allowed in class field initializer |
| [`ZNTC0617`](/zntc/reference/errors/zntc0617) | 'arguments' is not allowed in class static initializer |
| [`ZNTC0618`](/zntc/reference/errors/zntc0618) | String literal contains lone surrogate |
| [`ZNTC0619`](/zntc/reference/errors/zntc0619) | 'new.target' is not allowed outside of functions |

## 파서: 문/제어 흐름

| 코드 | 메시지 |
|------|--------|
| [`ZNTC0700`](/zntc/reference/errors/zntc0700) | 'return' outside of function |
| [`ZNTC0701`](/zntc/reference/errors/zntc0701) | 'break' outside of loop or switch |
| [`ZNTC0702`](/zntc/reference/errors/zntc0702) | 'continue' outside of loop |
| [`ZNTC0703`](/zntc/reference/errors/zntc0703) | Only one default clause is allowed in a switch statement |
| [`ZNTC0704`](/zntc/reference/errors/zntc0704) | Case or default expected |
| [`ZNTC0705`](/zntc/reference/errors/zntc0705) | Catch or finally expected |
| [`ZNTC0706`](/zntc/reference/errors/zntc0706) | No line break is allowed after 'throw' |
| [`ZNTC0707`](/zntc/reference/errors/zntc0707) | Escaped reserved word cannot be used as label |
| [`ZNTC0708`](/zntc/reference/errors/zntc0708) | Escaped reserved word cannot be used as label in strict mode |
| [`ZNTC0709`](/zntc/reference/errors/zntc0709) | Reserved word in strict mode cannot be used as label |

## 파서: strict mode

| 코드 | 메시지 |
|------|--------|
| [`ZNTC0800`](/zntc/reference/errors/zntc0800) | 'with' is not allowed in strict mode |
| [`ZNTC0801`](/zntc/reference/errors/zntc0801) | Octal literals are not allowed in strict mode |
| [`ZNTC0802`](/zntc/reference/errors/zntc0802) | Octal escape sequences are not allowed in strict mode |
| [`ZNTC0803`](/zntc/reference/errors/zntc0803) | Deleting an identifier is not allowed in strict mode |
| [`ZNTC0804`](/zntc/reference/errors/zntc0804) | \"use strict\" not allowed in function with non-simple parameters |
| [`ZNTC0805`](/zntc/reference/errors/zntc0805) | Cannot assign to or delete an imported binding |

## 파서: await/yield/JSX/TS

| 코드 | 메시지 |
|------|--------|
| [`ZNTC0900`](/zntc/reference/errors/zntc0900) | 'await' cannot be used as identifier in this context |
| [`ZNTC0901`](/zntc/reference/errors/zntc0901) | 'await' expression is not allowed in formal parameters |
| [`ZNTC0902`](/zntc/reference/errors/zntc0902) | 'await' is not allowed in class static initializer |
| [`ZNTC0903`](/zntc/reference/errors/zntc0903) | 'await' is not allowed in non-async function in module code |
| [`ZNTC0904`](/zntc/reference/errors/zntc0904) | 'await' is not allowed in arrow function parameters |
| [`ZNTC0905`](/zntc/reference/errors/zntc0905) | 'await' is not allowed in async arrow function parameters |
| [`ZNTC0906`](/zntc/reference/errors/zntc0906) | 'yield' expression is not allowed in formal parameters |
| [`ZNTC0907`](/zntc/reference/errors/zntc0907) | 'yield' is not allowed in arrow function parameters |
| [`ZNTC0908`](/zntc/reference/errors/zntc0908) | Invalid escape sequence in template literal |
| [`ZNTC0909`](/zntc/reference/errors/zntc0909) | Expected template continuation |
| [`ZNTC0910`](/zntc/reference/errors/zntc0910) | JSX tag name expected |
| [`ZNTC0911`](/zntc/reference/errors/zntc0911) | Spread expected |
| [`ZNTC0912`](/zntc/reference/errors/zntc0912) | Type expected |
| [`ZNTC0913`](/zntc/reference/errors/zntc0913) | Expected 'in' in mapped type |
| [`ZNTC0914`](/zntc/reference/errors/zntc0914) | Expected 'type' after 'opaque' |
| [`ZNTC0915`](/zntc/reference/errors/zntc0915) | Modifiers cannot appear on index signature parameters |
| [`ZNTC0916`](/zntc/reference/errors/zntc0916) | An index signature parameter cannot have a question mark |
| [`ZNTC0917`](/zntc/reference/errors/zntc0917) | 'yield' is not allowed outside generator function |
| [`ZNTC0918`](/zntc/reference/errors/zntc0918) | TypeScript syntax is not allowed in JavaScript source |

## 시맨틱: 재선언

| 코드 | 메시지 |
|------|--------|
| [`ZNTC1000`](/zntc/reference/errors/zntc1000) | Identifier has already been declared |
| [`ZNTC1001`](/zntc/reference/errors/zntc1001) | Cannot be used as a binding identifier in strict mode |

## 시맨틱: private

| 코드 | 메시지 |
|------|--------|
| [`ZNTC1100`](/zntc/reference/errors/zntc1100) | Private field has already been declared |
| [`ZNTC1101`](/zntc/reference/errors/zntc1101) | Private field must be declared in an enclosing class |

## 시맨틱: export/label

| 코드 | 메시지 |
|------|--------|
| [`ZNTC1200`](/zntc/reference/errors/zntc1200) | Duplicate export name |
| [`ZNTC1201`](/zntc/reference/errors/zntc1201) | Export is not defined |
| [`ZNTC1202`](/zntc/reference/errors/zntc1202) | Label has already been declared |
| [`ZNTC1203`](/zntc/reference/errors/zntc1203) | Cannot continue to non-loop label |
| [`ZNTC1204`](/zntc/reference/errors/zntc1204) | Undefined label |

## 시맨틱: class/기타

| 코드 | 메시지 |
|------|--------|
| [`ZNTC1300`](/zntc/reference/errors/zntc1300) | A class may only have one constructor |
| [`ZNTC1301`](/zntc/reference/errors/zntc1301) | Property name __proto__ appears more than once in object literal |
| [`ZNTC1302`](/zntc/reference/errors/zntc1302) | Getter must not have any formal parameters |
| [`ZNTC1303`](/zntc/reference/errors/zntc1303) | Setter must have exactly one formal parameter |
| [`ZNTC1400`](/zntc/reference/errors/zntc1400) | Type reference is not defined in the same file |
| [`ZNTC1401`](/zntc/reference/errors/zntc1401) | Prop type is not supported by codegen |
| [`ZNTC1402`](/zntc/reference/errors/zntc1402) | NativeProps body is not an object literal or known wrapper |
| [`ZNTC1403`](/zntc/reference/errors/zntc1403) | Duplicate component name in schema |
| [`ZNTC1404`](/zntc/reference/errors/zntc1404) | Inheritance / intersection chain exceeds depth limit |

## 트랜스포머

| 코드 | 메시지 |
|------|--------|
| [`ZNTC1500`](/zntc/reference/errors/zntc1500) | @jsx / @jsxFrag pragma ignored under the automatic JSX runtime |
| [`ZNTC1501`](/zntc/reference/errors/zntc1501) | Regular expression inline modifier group is an ES2025 feature not supported by the target |
