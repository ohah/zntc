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

describe("Flow RN: passing files (20/50)", () => {
  test("__flowtests__/ReactNativeTypes-flowtest.js", () =>
    expectPass("__flowtests__/ReactNativeTypes-flowtest.js"));
  test("ActionSheetIOS/NativeActionSheetManager.js", () =>
    expectPass("ActionSheetIOS/NativeActionSheetManager.js"));
  test("Alert/NativeAlertManager.js", () => expectPass("Alert/NativeAlertManager.js"));
  test("Alert/RCTAlertManager.js", () => expectPass("Alert/RCTAlertManager.js"));
  test("Animated/Animated.js", () => expectPass("Animated/Animated.js"));
  test("Animated/AnimatedExports.js", () => expectPass("Animated/AnimatedExports.js"));
  test("Animated/AnimatedPlatformConfig.js", () =>
    expectPass("Animated/AnimatedPlatformConfig.js"));
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
  test("Animated/NativeAnimatedAllowlist.js", () =>
    expectPass("Animated/NativeAnimatedAllowlist.js"));
  test("Animated/NativeAnimatedModule.js", () => expectPass("Animated/NativeAnimatedModule.js"));
  test("Animated/NativeAnimatedTurboModule.js", () =>
    expectPass("Animated/NativeAnimatedTurboModule.js"));
  test("Animated/nodes/AnimatedTracking.js", () =>
    expectPass("Animated/nodes/AnimatedTracking.js"));
  test("Animated/nodes/AnimatedWithChildren.js", () =>
    expectPass("Animated/nodes/AnimatedWithChildren.js"));
  test("Animated/shouldUseTurboAnimatedModule.js", () =>
    expectPass("Animated/shouldUseTurboAnimatedModule.js"));
  test("Animated/SpringConfig.js", () => expectPass("Animated/SpringConfig.js"));
  test("Animated/useAnimatedColor.js", () => expectPass("Animated/useAnimatedColor.js"));
});

describe("Flow RN: failing files (30/50) — fix하면 expectPass로 전환", () => {
  test("ActionSheetIOS/ActionSheetIOS.js", () => expectFail("ActionSheetIOS/ActionSheetIOS.js"));
  test("Alert/Alert.js", () => expectFail("Alert/Alert.js"));
  test("Alert/RCTAlertManager.android.js", () => expectFail("Alert/RCTAlertManager.android.js"));
  test("Alert/RCTAlertManager.ios.js", () => expectFail("Alert/RCTAlertManager.ios.js"));
  test("Animated/AnimatedEvent.js", () => expectFail("Animated/AnimatedEvent.js"));
  test("Animated/AnimatedImplementation.js", () =>
    expectFail("Animated/AnimatedImplementation.js"));
  test("Animated/AnimatedMock.js", () => expectFail("Animated/AnimatedMock.js"));
  test("Animated/animations/Animation.js", () => expectFail("Animated/animations/Animation.js"));
  test("Animated/animations/DecayAnimation.js", () =>
    expectFail("Animated/animations/DecayAnimation.js"));
  test("Animated/animations/SpringAnimation.js", () =>
    expectFail("Animated/animations/SpringAnimation.js"));
  test("Animated/animations/TimingAnimation.js", () =>
    expectFail("Animated/animations/TimingAnimation.js"));
  test("Animated/bezier.js", () => expectFail("Animated/bezier.js"));
  test("Animated/components/AnimatedScrollView.js", () =>
    expectFail("Animated/components/AnimatedScrollView.js"));
  test("Animated/createAnimatedComponent.js", () =>
    expectFail("Animated/createAnimatedComponent.js"));
  test("Animated/Easing.js", () => expectFail("Animated/Easing.js"));
  test("Animated/nodes/AnimatedAddition.js", () =>
    expectFail("Animated/nodes/AnimatedAddition.js"));
  test("Animated/nodes/AnimatedColor.js", () => expectFail("Animated/nodes/AnimatedColor.js"));
  test("Animated/nodes/AnimatedDiffClamp.js", () =>
    expectFail("Animated/nodes/AnimatedDiffClamp.js"));
  test("Animated/nodes/AnimatedDivision.js", () =>
    expectFail("Animated/nodes/AnimatedDivision.js"));
  test("Animated/nodes/AnimatedInterpolation.js", () =>
    expectFail("Animated/nodes/AnimatedInterpolation.js"));
  test("Animated/nodes/AnimatedModulo.js", () => expectFail("Animated/nodes/AnimatedModulo.js"));
  test("Animated/nodes/AnimatedMultiplication.js", () =>
    expectFail("Animated/nodes/AnimatedMultiplication.js"));
  test("Animated/nodes/AnimatedNode.js", () => expectFail("Animated/nodes/AnimatedNode.js"));
  test("Animated/nodes/AnimatedObject.js", () => expectFail("Animated/nodes/AnimatedObject.js"));
  test("Animated/nodes/AnimatedProps.js", () => expectFail("Animated/nodes/AnimatedProps.js"));
  test("Animated/nodes/AnimatedStyle.js", () => expectFail("Animated/nodes/AnimatedStyle.js"));
  test("Animated/nodes/AnimatedSubtraction.js", () =>
    expectFail("Animated/nodes/AnimatedSubtraction.js"));
  test("Animated/nodes/AnimatedTransform.js", () =>
    expectFail("Animated/nodes/AnimatedTransform.js"));
  test("Animated/nodes/AnimatedValue.js", () => expectFail("Animated/nodes/AnimatedValue.js"));
  test("Animated/nodes/AnimatedValueXY.js", () => expectFail("Animated/nodes/AnimatedValueXY.js"));
});
