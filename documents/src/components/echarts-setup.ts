/**
 * ECharts core + 사용 중인 charts/components/renderers 의 단일 register 지점.
 *
 * `echarts.use()` 는 module-global 이라 어디서 호출하든 효과는 같지만, 여러 컴포넌트가
 * 각자 부분집합만 register 하면 두 chunk 가 분리될 때 사용자가 "왜 이 chart 만 안 그려지지"
 * 라는 디버깅을 유발. 한 곳에 모아 union register 하고 호출자는 이 모듈에서 `echarts` 만 import.
 */

import * as echarts from "echarts/core";
import { BarChart, GraphChart, TreemapChart } from "echarts/charts";
import { GridComponent, LegendComponent, TooltipComponent } from "echarts/components";
import { CanvasRenderer } from "echarts/renderers";

echarts.use([
  BarChart,
  TreemapChart,
  GraphChart,
  TooltipComponent,
  GridComponent,
  LegendComponent,
  CanvasRenderer,
]);

export { echarts };
