---
title: 에러 코드 레퍼런스
description: ZTS 에러 코드 전체 목록
---

ZTS는 모든 에러에 고유 코드를 부여합니다. 에러 코드를 클릭하면 상세 설명과 재현 코드를 볼 수 있습니다.


## 타겟/호환성

| 코드 | 메시지 |
|------|--------|
| [`ZTS0001`](/zts/reference/errors/zts0001) | Top-level await is not available in the configured target environment |

## 번들러: import/export

| 코드 | 메시지 |
|------|--------|
| [`ZTS0100`](/zts/reference/errors/zts0100) | Could not resolve import |
| [`ZTS0101`](/zts/reference/errors/zts0101) | Export not found in module |
| [`ZTS0102`](/zts/reference/errors/zts0102) | Circular dependency detected |
| [`ZTS0103`](/zts/reference/errors/zts0103) | Module resolution failed |
| [`ZTS0104`](/zts/reference/errors/zts0104) | Re-export references the module itself (self-cycle) |

## 번들러: 파일/로더

| 코드 | 메시지 |
|------|--------|
| [`ZTS0200`](/zts/reference/errors/zts0200) | Failed to read file |
| [`ZTS0201`](/zts/reference/errors/zts0201) | Failed to parse JSON |
| [`ZTS0202`](/zts/reference/errors/zts0202) | No loader is configured for this file type |

## 파서: import/export

| 코드 | 메시지 |
|------|--------|
| [`ZTS0300`](/zts/reference/errors/zts0300) | 'import' declaration is only allowed in module code |
| [`ZTS0301`](/zts/reference/errors/zts0301) | 'import' declaration must be at the top level |
| [`ZTS0302`](/zts/reference/errors/zts0302) | 'import defer/source' requires a binding |
| [`ZTS0303`](/zts/reference/errors/zts0303) | String literal in import specifier requires 'as' binding |
| [`ZTS0304`](/zts/reference/errors/zts0304) | Duplicate import attribute key |
| [`ZTS0305`](/zts/reference/errors/zts0305) | 'export' declaration is only allowed in module code |
| [`ZTS0306`](/zts/reference/errors/zts0306) | 'export' declaration must be at the top level |
| [`ZTS0307`](/zts/reference/errors/zts0307) | String literal cannot be used as local binding in export |
| [`ZTS0308`](/zts/reference/errors/zts0308) | Module source string expected |
| [`ZTS0309`](/zts/reference/errors/zts0309) | 'export' is not allowed in statement position |
| [`ZTS0310`](/zts/reference/errors/zts0310) | 'import' is not allowed in statement position |
| [`ZTS0311`](/zts/reference/errors/zts0311) | 'import' cannot be used with 'new' |
| [`ZTS0312`](/zts/reference/errors/zts0312) | 'import.meta' is only allowed in module code |
| [`ZTS0313`](/zts/reference/errors/zts0313) | Expected 'import.meta', 'import.source', or 'import.defer' |
| [`ZTS0314`](/zts/reference/errors/zts0314) | 'import.source'/'import.defer' requires arguments |

## 파서: 선언/클래스

| 코드 | 메시지 |
|------|--------|
| [`ZTS0400`](/zts/reference/errors/zts0400) | Anonymous function declaration cannot be invoked |
| [`ZTS0401`](/zts/reference/errors/zts0401) | Function declaration is not allowed in statement position |
| [`ZTS0402`](/zts/reference/errors/zts0402) | Function declaration is not allowed in statement position in strict mode |
| [`ZTS0403`](/zts/reference/errors/zts0403) | Generator declaration is not allowed in statement position |
| [`ZTS0404`](/zts/reference/errors/zts0404) | Async function declaration is not allowed in statement position |
| [`ZTS0405`](/zts/reference/errors/zts0405) | Class declaration is not allowed in statement position |
| [`ZTS0406`](/zts/reference/errors/zts0406) | Class constructor cannot be a getter, setter, generator, or async |
| [`ZTS0407`](/zts/reference/errors/zts0407) | Class member cannot be named '#constructor' |
| [`ZTS0408`](/zts/reference/errors/zts0408) | Class field cannot be named 'constructor' |
| [`ZTS0409`](/zts/reference/errors/zts0409) | Static class field cannot be named 'prototype' |
| [`ZTS0410`](/zts/reference/errors/zts0410) | Static class method cannot be named 'prototype' |
| [`ZTS0411`](/zts/reference/errors/zts0411) | Class expected after decorator |
| [`ZTS0412`](/zts/reference/errors/zts0412) | Class or export expected after decorator |
| [`ZTS0413`](/zts/reference/errors/zts0413) | Labelled function declaration is not allowed in loop body |
| [`ZTS0414`](/zts/reference/errors/zts0414) | Lexical declaration is not allowed in statement position |

## 파서: 바인딩/식별자

| 코드 | 메시지 |
|------|--------|
| [`ZTS0500`](/zts/reference/errors/zts0500) | Identifier expected |
| [`ZTS0501`](/zts/reference/errors/zts0501) | Binding pattern expected |
| [`ZTS0502`](/zts/reference/errors/zts0502) | Escaped reserved word cannot be used as identifier |
| [`ZTS0503`](/zts/reference/errors/zts0503) | Escaped reserved word cannot be used as identifier in strict mode |
| [`ZTS0504`](/zts/reference/errors/zts0504) | Reserved word cannot be used as identifier |
| [`ZTS0505`](/zts/reference/errors/zts0505) | Reserved word in strict mode cannot be used as identifier |
| [`ZTS0506`](/zts/reference/errors/zts0506) | Keywords cannot contain escape characters |
| [`ZTS0507`](/zts/reference/errors/zts0507) | 'let' is not allowed as variable name in lexical declaration |
| [`ZTS0508`](/zts/reference/errors/zts0508) | Const declarations must be initialized |
| [`ZTS0509`](/zts/reference/errors/zts0509) | 'async' is not allowed as identifier in for-of left-hand side |
| [`ZTS0510`](/zts/reference/errors/zts0510) | 'let' is not allowed as identifier in for-of left-hand side |
| [`ZTS0511`](/zts/reference/errors/zts0511) | Only a single variable declaration is allowed in a for-in/for-of statement |
| [`ZTS0512`](/zts/reference/errors/zts0512) | For-in/for-of loop variable declaration may not have an initializer |
| [`ZTS0513`](/zts/reference/errors/zts0513) | Rest element must be last element |
| [`ZTS0514`](/zts/reference/errors/zts0514) | Rest element may not have a trailing comma |
| [`ZTS0515`](/zts/reference/errors/zts0515) | Duplicate parameter name |
| [`ZTS0516`](/zts/reference/errors/zts0516) | Private name is not allowed in destructuring pattern |
| [`ZTS0517`](/zts/reference/errors/zts0517) | Invalid assignment target |
| [`ZTS0518`](/zts/reference/errors/zts0518) | Assignment to 'eval' or 'arguments' is not allowed in strict mode |

## 파서: 식/연산자

| 코드 | 메시지 |
|------|--------|
| [`ZTS0600`](/zts/reference/errors/zts0600) | Expression expected |
| [`ZTS0601`](/zts/reference/errors/zts0601) | Unary expression cannot be the left operand of '**' |
| [`ZTS0602`](/zts/reference/errors/zts0602) | Cannot mix '??' with '&&' or '||' without parentheses |
| [`ZTS0603`](/zts/reference/errors/zts0603) | Private name is not valid outside of 'in' expression |
| [`ZTS0604`](/zts/reference/errors/zts0604) | Private name is not valid as right-hand side of 'in' expression |
| [`ZTS0605`](/zts/reference/errors/zts0605) | Private fields cannot be deleted |
| [`ZTS0606`](/zts/reference/errors/zts0606) | Private field access on super is not allowed |
| [`ZTS0620`](/zts/reference/errors/zts0620) | 'super' is not allowed outside of a method |
| [`ZTS0621`](/zts/reference/errors/zts0621) | 'super()' is only allowed in a class constructor |
| [`ZTS0607`](/zts/reference/errors/zts0607) | Tagged template cannot be used in optional chain |
| [`ZTS0608`](/zts/reference/errors/zts0608) | Property key expected |
| [`ZTS0609`](/zts/reference/errors/zts0609) | Expected ':' after property key |
| [`ZTS0610`](/zts/reference/errors/zts0610) | Invalid shorthand property initializer |
| [`ZTS0611`](/zts/reference/errors/zts0611) | Reserved word cannot be used as shorthand property |
| [`ZTS0612`](/zts/reference/errors/zts0612) | Reserved word in strict mode cannot be used as shorthand property |
| [`ZTS0613`](/zts/reference/errors/zts0613) | 'yield' cannot be used as shorthand property in generator |
| [`ZTS0614`](/zts/reference/errors/zts0614) | 'await' cannot be used as shorthand property in async/module |
| [`ZTS0615`](/zts/reference/errors/zts0615) | Private identifier is not allowed as object property key |
| [`ZTS0616`](/zts/reference/errors/zts0616) | 'arguments' is not allowed in class field initializer |
| [`ZTS0617`](/zts/reference/errors/zts0617) | 'arguments' is not allowed in class static initializer |
| [`ZTS0618`](/zts/reference/errors/zts0618) | String literal contains lone surrogate |
| [`ZTS0619`](/zts/reference/errors/zts0619) | 'new.target' is not allowed outside of functions |

## 파서: 문/제어 흐름

| 코드 | 메시지 |
|------|--------|
| [`ZTS0700`](/zts/reference/errors/zts0700) | 'return' outside of function |
| [`ZTS0701`](/zts/reference/errors/zts0701) | 'break' outside of loop or switch |
| [`ZTS0702`](/zts/reference/errors/zts0702) | 'continue' outside of loop |
| [`ZTS0703`](/zts/reference/errors/zts0703) | Only one default clause is allowed in a switch statement |
| [`ZTS0704`](/zts/reference/errors/zts0704) | Case or default expected |
| [`ZTS0705`](/zts/reference/errors/zts0705) | Catch or finally expected |
| [`ZTS0706`](/zts/reference/errors/zts0706) | No line break is allowed after 'throw' |
| [`ZTS0707`](/zts/reference/errors/zts0707) | Escaped reserved word cannot be used as label |
| [`ZTS0708`](/zts/reference/errors/zts0708) | Escaped reserved word cannot be used as label in strict mode |
| [`ZTS0709`](/zts/reference/errors/zts0709) | Reserved word in strict mode cannot be used as label |

## 파서: strict mode

| 코드 | 메시지 |
|------|--------|
| [`ZTS0800`](/zts/reference/errors/zts0800) | 'with' is not allowed in strict mode |
| [`ZTS0801`](/zts/reference/errors/zts0801) | Octal literals are not allowed in strict mode |
| [`ZTS0802`](/zts/reference/errors/zts0802) | Octal escape sequences are not allowed in strict mode |
| [`ZTS0803`](/zts/reference/errors/zts0803) | Deleting an identifier is not allowed in strict mode |
| [`ZTS0804`](/zts/reference/errors/zts0804) | \"use strict\" not allowed in function with non-simple parameters |

## 파서: await/yield/JSX/TS

| 코드 | 메시지 |
|------|--------|
| [`ZTS0900`](/zts/reference/errors/zts0900) | 'await' cannot be used as identifier in this context |
| [`ZTS0901`](/zts/reference/errors/zts0901) | 'await' expression is not allowed in formal parameters |
| [`ZTS0902`](/zts/reference/errors/zts0902) | 'await' is not allowed in class static initializer |
| [`ZTS0903`](/zts/reference/errors/zts0903) | 'await' is not allowed in non-async function in module code |
| [`ZTS0904`](/zts/reference/errors/zts0904) | 'await' is not allowed in arrow function parameters |
| [`ZTS0905`](/zts/reference/errors/zts0905) | 'await' is not allowed in async arrow function parameters |
| [`ZTS0906`](/zts/reference/errors/zts0906) | 'yield' expression is not allowed in formal parameters |
| [`ZTS0907`](/zts/reference/errors/zts0907) | 'yield' is not allowed in arrow function parameters |
| [`ZTS0908`](/zts/reference/errors/zts0908) | Invalid escape sequence in template literal |
| [`ZTS0909`](/zts/reference/errors/zts0909) | Expected template continuation |
| [`ZTS0910`](/zts/reference/errors/zts0910) | JSX tag name expected |
| [`ZTS0911`](/zts/reference/errors/zts0911) | Spread expected |
| [`ZTS0912`](/zts/reference/errors/zts0912) | Type expected |
| [`ZTS0913`](/zts/reference/errors/zts0913) | Expected 'in' in mapped type |
| [`ZTS0914`](/zts/reference/errors/zts0914) | Expected 'type' after 'opaque' |

## 시맨틱: 재선언

| 코드 | 메시지 |
|------|--------|
| [`ZTS1000`](/zts/reference/errors/zts1000) | Identifier has already been declared |
| [`ZTS1001`](/zts/reference/errors/zts1001) | Cannot be used as a binding identifier in strict mode |

## 시맨틱: private

| 코드 | 메시지 |
|------|--------|
| [`ZTS1100`](/zts/reference/errors/zts1100) | Private field has already been declared |
| [`ZTS1101`](/zts/reference/errors/zts1101) | Private field must be declared in an enclosing class |

## 시맨틱: export/label

| 코드 | 메시지 |
|------|--------|
| [`ZTS1200`](/zts/reference/errors/zts1200) | Duplicate export name |
| [`ZTS1201`](/zts/reference/errors/zts1201) | Export is not defined |
| [`ZTS1202`](/zts/reference/errors/zts1202) | Label has already been declared |
| [`ZTS1203`](/zts/reference/errors/zts1203) | Cannot continue to non-loop label |
| [`ZTS1204`](/zts/reference/errors/zts1204) | Undefined label |

## 시맨틱: class/기타

| 코드 | 메시지 |
|------|--------|
| [`ZTS1300`](/zts/reference/errors/zts1300) | A class may only have one constructor |
| [`ZTS1301`](/zts/reference/errors/zts1301) | Property name __proto__ appears more than once in object literal |
| [`ZTS1302`](/zts/reference/errors/zts1302) | Getter must not have any formal parameters |
| [`ZTS1303`](/zts/reference/errors/zts1303) | Setter must have exactly one formal parameter |
