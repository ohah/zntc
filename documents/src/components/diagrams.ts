/**
 * Mermaid diagram source 모음. 한/영 페이지가 동일 다이어그램을 import 해
 * drift 차단. 노드 텍스트는 영어 위주 + 짧은 한글 keyword 만 (locale-neutral).
 */

export const NAPI_ARCHITECTURE_CHART = `flowchart TD
    UC[User Code<br/>Node / Bun / Vite]
    JS[<b>@zts/core JS layer</b><br/>transpile · build · watch<br/>defineConfig · vitePlugin]
    PD[Plugin Dispatcher<br/>onResolve · onLoad<br/>onTransform · lifecycle]
    NAPI[zts.node<br/>NAPI v8 addon]

    subgraph Native["Zig Native Engine"]
        direction TB
        Lex[Lexer / Scanner]
        Parse[Parser<br/>TS · JSX · Flow · Decorators]
        Sem[Semantic Analyzer<br/>scope · symbol · references]
        Trans[Transformer<br/>type strip · JSX · downlevel]
        CG[Codegen]
        Bundle[Bundler<br/>resolver · graph]
        Link[Linker<br/>scope hoisting · imports]
        Shake[Tree Shaker<br/>statement · symbol · purity]
        Emit[Emitter<br/>chunk · sourcemap · assets]

        Lex --> Parse --> Sem --> Trans --> CG
        Parse -.-> Bundle
        Bundle --> Link --> Shake --> Emit
    end

    UC --> JS
    JS <--> PD
    JS --> NAPI
    NAPI <--> Native
    PD <-.threadsafe callback.-> NAPI
`;
