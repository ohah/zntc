/**
 * Mermaid diagram source 모음. 한/영 페이지가 동일 다이어그램을 import 해
 * drift 차단. 노드 텍스트는 영어 위주 + 짧은 한글 keyword 만 (locale-neutral).
 */

export const NAPI_ARCHITECTURE_CHART = `flowchart TB
    UC["User Code<br/>Node · Bun · Vite"]

    subgraph JSLayer["JavaScript Surface"]
        direction TB
        API["Public API<br/>transpile · build · watch"]
        Config["Config Layer<br/>defineConfig · vitePlugin"]
        PD["Plugin Dispatcher<br/>resolve · load · transform"]
        Config --> API
        API <--> PD
    end

    NAPI["NAPI Bridge<br/>zts.node · JSON payload"]

    subgraph Native["Zig Native Engine"]
        direction TB
        Frontend["Frontend<br/>scan · parse · semantic"]
        Transform["Transform<br/>downlevel · minify · helpers"]
        Bundle["Bundle<br/>resolver · graph · linker"]
        Emit["Emit<br/>tree shake · chunks · sourcemaps"]

        Frontend --> Transform --> Bundle --> Emit
    end

    UC --> API
    API --> NAPI
    PD -. "threadsafe callback" .-> NAPI
    NAPI --> Frontend

    classDef entry fill:#fff7ed,stroke:#f7a41d,color:#431407,stroke-width:1.4px;
    classDef js fill:#ffedd5,stroke:#fb923c,color:#431407,stroke-width:1.2px;
    classDef bridge fill:#f7a41d,stroke:#fed7aa,color:#1c1816,stroke-width:1.6px;
    classDef native fill:#fafaf9,stroke:#d6d3d1,color:#1c1816,stroke-width:1.2px;

    class UC entry;
    class API,Config,PD js;
    class NAPI bridge;
    class Frontend,Transform,Bundle,Emit native;
`;
