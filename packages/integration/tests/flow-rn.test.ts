import { describe, test, expect } from "bun:test";
import { ZTS_BIN } from "./helpers";
import { resolve } from "node:path";

/**
 * React Native Flow 파싱 회귀 테스트.
 * references/react-native에서 복사한 실제 RN Libraries 파일 50개를
 * --flow --jsx-in-js로 트랜스파일하여 파서 호환성을 추적한다.
 *
 * 현재 통과하는 파일은 expectPass, 실패하는 파일은 expectFail로 분류.
 * Flow 파서를 개선할 때마다 expectFail → expectPass로 전환하여 진행률을 확인.
 */

const FIXTURES = resolve(import.meta.dir, "fixtures/react-native");

async function transpile(file: string): Promise<{ exitCode: number; stderr: string }> {
  const filePath = resolve(FIXTURES, file);
  const proc = Bun.spawnSync([ZTS_BIN, "--flow", "--jsx-in-js", filePath]);
  return {
    exitCode: proc.exitCode,
    stderr: proc.stderr.toString(),
  };
}

async function expectPass(file: string) {
  const result = await transpile(file);
  expect(result.exitCode).toBe(0);
  expect(result.stderr).not.toContain("error:");
}

async function expectFail(file: string) {
  const result = await transpile(file);
  const hasError = result.exitCode !== 0 || result.stderr.includes("error:");
  expect(hasError).toBe(true);
}

describe("Flow RN: passing files (47/50)", () => {
  test("__flowtests__/ReactNativeTypes-flowtest.js", () =>
    expectPass("__flowtests__/ReactNativeTypes-flowtest.js"));
  test("ActionSheetIOS/ActionSheetIOS.js", () => expectPass("ActionSheetIOS/ActionSheetIOS.js"));
  test("ActionSheetIOS/NativeActionSheetManager.js", () =>
    expectPass("ActionSheetIOS/NativeActionSheetManager.js"));
  test("Alert/Alert.js", () => expectPass("Alert/Alert.js"));
  test("Alert/NativeAlertManager.js", () => expectPass("Alert/NativeAlertManager.js"));
  test("Alert/RCTAlertManager.js", () => expectPass("Alert/RCTAlertManager.js"));
  test("Alert/RCTAlertManager.android.js", () => expectPass("Alert/RCTAlertManager.android.js"));
  test("Alert/RCTAlertManager.ios.js", () => expectPass("Alert/RCTAlertManager.ios.js"));
  test("Animated/Animated.js", () => expectPass("Animated/Animated.js"));
  test("Animated/AnimatedEvent.js", () => expectPass("Animated/AnimatedEvent.js"));
  test("Animated/AnimatedExports.js", () => expectPass("Animated/AnimatedExports.js"));
  test("Animated/AnimatedImplementation.js", () =>
    expectPass("Animated/AnimatedImplementation.js"));
  test("Animated/AnimatedMock.js", () => expectPass("Animated/AnimatedMock.js"));
  test("Animated/AnimatedPlatformConfig.js", () =>
    expectPass("Animated/AnimatedPlatformConfig.js"));
  test("Animated/Easing.js", () => expectPass("Animated/Easing.js"));
  test("Animated/NativeAnimatedAllowlist.js", () =>
    expectPass("Animated/NativeAnimatedAllowlist.js"));
  test("Animated/NativeAnimatedModule.js", () => expectPass("Animated/NativeAnimatedModule.js"));
  test("Animated/NativeAnimatedTurboModule.js", () =>
    expectPass("Animated/NativeAnimatedTurboModule.js"));
  test("Animated/SpringConfig.js", () => expectPass("Animated/SpringConfig.js"));
  test("Animated/animations/Animation.js", () => expectPass("Animated/animations/Animation.js"));
  test("Animated/animations/DecayAnimation.js", () =>
    expectPass("Animated/animations/DecayAnimation.js"));
  test("Animated/animations/SpringAnimation.js", () =>
    expectPass("Animated/animations/SpringAnimation.js"));
  test("Animated/animations/TimingAnimation.js", () =>
    expectPass("Animated/animations/TimingAnimation.js"));
  test("Animated/bezier.js", () => expectPass("Animated/bezier.js"));
  test("Animated/components/AnimatedFlatList.js", () =>
    expectPass("Animated/components/AnimatedFlatList.js"));
  test("Animated/components/AnimatedImage.js", () =>
    expectPass("Animated/components/AnimatedImage.js"));
  test("Animated/components/AnimatedSectionList.js", () =>
    expectPass("Animated/components/AnimatedSectionList.js"));
  test("Animated/components/AnimatedText.js", () =>
    expectPass("Animated/components/AnimatedText.js"));
  test("Animated/components/AnimatedView.js", () =>
    expectPass("Animated/components/AnimatedView.js"));
  test("Animated/nodes/AnimatedAddition.js", () =>
    expectPass("Animated/nodes/AnimatedAddition.js"));
  test("Animated/nodes/AnimatedColor.js", () => expectPass("Animated/nodes/AnimatedColor.js"));
  test("Animated/nodes/AnimatedDiffClamp.js", () =>
    expectPass("Animated/nodes/AnimatedDiffClamp.js"));
  test("Animated/nodes/AnimatedDivision.js", () =>
    expectPass("Animated/nodes/AnimatedDivision.js"));
  test("Animated/nodes/AnimatedModulo.js", () => expectPass("Animated/nodes/AnimatedModulo.js"));
  test("Animated/nodes/AnimatedMultiplication.js", () =>
    expectPass("Animated/nodes/AnimatedMultiplication.js"));
  test("Animated/nodes/AnimatedNode.js", () => expectPass("Animated/nodes/AnimatedNode.js"));
  test("Animated/nodes/AnimatedObject.js", () => expectPass("Animated/nodes/AnimatedObject.js"));
  test("Animated/nodes/AnimatedProps.js", () => expectPass("Animated/nodes/AnimatedProps.js"));
  test("Animated/nodes/AnimatedStyle.js", () => expectPass("Animated/nodes/AnimatedStyle.js"));
  test("Animated/nodes/AnimatedSubtraction.js", () =>
    expectPass("Animated/nodes/AnimatedSubtraction.js"));
  test("Animated/nodes/AnimatedTracking.js", () =>
    expectPass("Animated/nodes/AnimatedTracking.js"));
  test("Animated/nodes/AnimatedTransform.js", () =>
    expectPass("Animated/nodes/AnimatedTransform.js"));
  test("Animated/nodes/AnimatedValue.js", () => expectPass("Animated/nodes/AnimatedValue.js"));
  test("Animated/nodes/AnimatedValueXY.js", () => expectPass("Animated/nodes/AnimatedValueXY.js"));
  test("Animated/nodes/AnimatedWithChildren.js", () =>
    expectPass("Animated/nodes/AnimatedWithChildren.js"));
  test("Animated/shouldUseTurboAnimatedModule.js", () =>
    expectPass("Animated/shouldUseTurboAnimatedModule.js"));
  test("Animated/useAnimatedColor.js", () => expectPass("Animated/useAnimatedColor.js"));
});

describe("Flow RN: failing files (3/50) — fix하면 expectPass로 전환", () => {
  // conditional type + infer + mapped type
  test("Animated/createAnimatedComponent.js", () =>
    expectFail("Animated/createAnimatedComponent.js"));
  // shorthand 함수 타입이 반환 타입 위치에서 충돌
  test("Animated/nodes/AnimatedInterpolation.js", () =>
    expectFail("Animated/nodes/AnimatedInterpolation.js"));
  // component syntax + cascading
  test("Animated/components/AnimatedScrollView.js", () =>
    expectFail("Animated/components/AnimatedScrollView.js"));
});
