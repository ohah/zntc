/**
 * Mermaid diagram source 모음. 한/영 페이지가 동일 다이어그램을 import 해
 * drift 차단. 노드 텍스트는 영어 위주 + 짧은 한글 keyword 만 (locale-neutral).
 */

export const BUNDLER_PIPELINE_CHART = `flowchart TB
    Entry["Entry Points"]
    Resolver["Resolver<br/>경로 → 절대 파일 경로"]
    Graph["Module Graph<br/>BFS 파싱 · DFS 실행 순서"]
    Linker["Linker<br/>스코프 호이스팅 · 이름 충돌"]
    Tree["Tree-shaker<br/>미사용 export · 문장 제거"]
    Chunker["Chunker<br/>동적 import → 청크 분할"]
    Emitter["Emitter<br/>transform · codegen"]
    Output["Output<br/>bundle.js · chunks · .map"]

    Entry --> Resolver --> Graph --> Linker --> Tree --> Chunker --> Emitter --> Output

    classDef entry fill:#fff7ed,stroke:#f7a41d,color:#431407,stroke-width:1.4px;
    classDef stage fill:#ffedd5,stroke:#fb923c,color:#431407,stroke-width:1.2px;
    classDef out fill:#f7a41d,stroke:#fed7aa,color:#1c1816,stroke-width:1.6px;

    class Entry entry;
    class Resolver,Graph,Linker,Tree,Chunker,Emitter stage;
    class Output out;
`;

export const BUNDLER_CIRCULAR_DEPS_CHART = `flowchart LR
    A["a.ts<br/>export const A = () => B()"]
    B["b.ts<br/>export const B = () => A()"]

    A -->|"import { B }"| B
    B -->|"import { A }"| A

    classDef mod fill:#ffedd5,stroke:#fb923c,color:#431407,stroke-width:1.2px;
    class A,B mod;
`;

export const BUNDLER_CJS_ESM_INTEROP_CHART = `flowchart TD
    Start{"Importer 종류"}
    Mjs[".mjs · .mts<br/>package.json type: module"]
    Other["기타<br/>.js · .ts · 일반 import"]
    NodeMode["Node 모드<br/>__toESM(require(), 1)<br/>Node.js 기본 동작"]
    BabelMode["Babel 모드<br/>__toESM(require())<br/>__esModule 플래그 존중"]

    Start --> Mjs
    Start --> Other
    Mjs --> NodeMode
    Other --> BabelMode

    classDef decision fill:#fff7ed,stroke:#f7a41d,color:#431407,stroke-width:1.4px;
    classDef branch fill:#ffedd5,stroke:#fb923c,color:#431407,stroke-width:1.2px;
    classDef result fill:#f7a41d,stroke:#fed7aa,color:#1c1816,stroke-width:1.6px;

    class Start decision;
    class Mjs,Other branch;
    class NodeMode,BabelMode result;
`;

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

    NAPI["NAPI Bridge<br/>zntc.node · JSON payload"]

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
