/**
 * ZNTC Large RN Fixture
 * Cold-build perf testing — large dep surface (navigation + query + redux + forms + icons + charts)
 *
 * NOTE: 이 fixture 는 빌드 perf 측정 전용 — 런타임 동작은 보장 안 함. 새 dep 들의 entry 만
 * import 해 graph 가 그 트랜지티브 의존성을 다 끌어오게 한다 (tree-shake 회피).
 */

// --- navigation
import { NavigationContainer } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { createDrawerNavigator } from '@react-navigation/drawer';

// --- data fetching
import {
  QueryClient,
  QueryClientProvider,
  useQuery,
  useMutation,
  useInfiniteQuery,
} from '@tanstack/react-query';
import axios from 'axios';

// --- state
import { configureStore, createSlice, createAsyncThunk } from '@reduxjs/toolkit';
import { Provider as ReduxProvider, useSelector, useDispatch } from 'react-redux';
import { persistStore, persistReducer } from 'redux-persist';

// --- forms
import { useForm, Controller, FormProvider } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { Formik, Form, Field } from 'formik';
import * as yup from 'yup';

// --- date / utils
import {
  format as dfFormat,
  parseISO,
  addDays,
  differenceInDays,
  startOfMonth,
  endOfMonth,
} from 'date-fns';
import dayjs from 'dayjs';
import _ from 'lodash';

// --- icons
import Icon from 'react-native-vector-icons/MaterialIcons';
import FAIcon from 'react-native-vector-icons/FontAwesome';
import Ionicons from 'react-native-vector-icons/Ionicons';

// --- storage
import { MMKV } from 'react-native-mmkv';
import AsyncStorage from '@react-native-async-storage/async-storage';

// --- monitoring
import * as Sentry from '@sentry/react-native';

// --- firebase
import firebase from '@react-native-firebase/app';
import auth from '@react-native-firebase/auth';
import firestore from '@react-native-firebase/firestore';
import analytics from '@react-native-firebase/analytics';
import messaging from '@react-native-firebase/messaging';
import crashlytics from '@react-native-firebase/crashlytics';

// --- UI kit
import { Provider as PaperProvider, Button, Card, Appbar, TextInput as PaperInput } from 'react-native-paper';
import { TabView, SceneMap } from 'react-native-tab-view';
import PagerView from 'react-native-pager-view';

// --- notifications
import notifee from '@notifee/react-native';

// --- payments / security
import * as RNIap from 'react-native-iap';
import * as Keychain from 'react-native-keychain';

// --- system
import RNConfig from 'react-native-config';
import * as RNLocalize from 'react-native-localize';
import i18n from 'i18next';
import { useTranslation, initReactI18next } from 'react-i18next';
import Clipboard from '@react-native-clipboard/clipboard';
import NetInfo from '@react-native-community/netinfo';
import DateTimePicker from '@react-native-community/datetimepicker';
import * as ImagePicker from 'react-native-image-picker';
import * as Permissions from 'react-native-permissions';
import FastImage from 'react-native-fast-image';
import LinearGradient from 'react-native-linear-gradient';
import Modal from 'react-native-modal';

// --- time / utils
import moment from 'moment';
import 'moment-timezone';
import * as R from 'ramda';
import { produce, immerable } from 'immer';

// --- graphql
import { ApolloClient, ApolloProvider, gql, InMemoryCache, useQuery as useApolloQuery } from '@apollo/client';

// --- styled
import styled from 'styled-components/native';

// --- batch 3: reactive / state / extra UI / utils
import { Observable, Subject, BehaviorSubject, of, from, map as rxMap, filter as rxFilter, debounceTime, switchMap, catchError as rxCatchError } from 'rxjs';
import { observable, action, computed, autorun, reaction, makeObservable } from 'mobx';
import { observer } from 'mobx-react-lite';
import Toast from 'react-native-toast-message';
import SegmentedControl from '@react-native-segmented-control/segmented-control';
import LottieView from 'lottie-react-native';
import Slider from '@react-native-community/slider';
import BouncyCheckbox from 'react-native-bouncy-checkbox';
import * as Orientation from 'react-native-orientation-locker';
import Tooltip from 'react-native-walkthrough-tooltip';
import { Toaster, toast as hotToast } from 'react-hot-toast';
import { useDebounce, useDebouncedCallback } from 'use-debounce';
import validator from 'validator';
import { v4 as uuidv4, v1 as uuidv1, v5 as uuidv5 } from 'uuid';
import deepmerge from 'deepmerge';
import * as qs from 'qs';
import * as queryString from 'query-string';
import RNUUID from 'react-native-uuid';

// lodash submodule sweep — trans-deps 확장
import 'lodash/array';
import 'lodash/collection';
import 'lodash/date';
import 'lodash/function';
import 'lodash/lang';
import 'lodash/math';
import 'lodash/number';
import 'lodash/object';
import 'lodash/seq';
import 'lodash/string';
import 'lodash/util';
import 'lodash/fp';

// date-fns submodule sweep
import 'date-fns/locale';

void Observable; void Subject; void BehaviorSubject; void of; void from; void rxMap; void rxFilter; void debounceTime; void switchMap; void rxCatchError;
void observable; void action; void computed; void autorun; void reaction; void makeObservable; void observer;
void Toast; void SegmentedControl; void LottieView; void Slider; void BouncyCheckbox;
void Orientation; void Tooltip; void Toaster; void hotToast;
void useDebounce; void useDebouncedCallback; void validator; void uuidv4; void uuidv1; void uuidv5;
void deepmerge; void qs; void queryString; void RNUUID;

// --- batch 4: firebase extra + aws-amplify + stripe + wallet + ethers + intl
import db from '@react-native-firebase/database';
import storage from '@react-native-firebase/storage';
import functions from '@react-native-firebase/functions';
import remoteConfig from '@react-native-firebase/remote-config';
import dynamicLinks from '@react-native-firebase/dynamic-links';
import perf from '@react-native-firebase/perf';
import appCheck from '@react-native-firebase/app-check';
import iam from '@react-native-firebase/in-app-messaging';
import installations from '@react-native-firebase/installations';

import { StripeProvider, useStripe, useConfirmPayment } from '@stripe/stripe-react-native';
import { Dropdown } from 'react-native-element-dropdown';
import Snackbar from 'react-native-snackbar';
import { Slider as MibSlider } from '@miblanchard/react-native-slider';
import Share from 'react-native-share';
import { ReactQueryDevtools } from '@tanstack/react-query-devtools';
import { QueryCache, MutationCache } from '@tanstack/query-core';
import ReactNativeHapticFeedback from 'react-native-haptic-feedback';
import RNBootSplash from 'react-native-bootsplash';
import DeviceInfo from 'react-native-device-info';
import DocumentPicker from 'react-native-document-picker';
import EncryptedStorage from 'react-native-encrypted-storage';
import { RSA } from 'react-native-rsa-native';

import '@walletconnect/react-native-compat';
import { ethers, BrowserProvider, Wallet, JsonRpcProvider, parseEther, formatEther } from 'ethers';
import { Connection, PublicKey, Keypair, LAMPORTS_PER_SOL, SystemProgram } from '@solana/web3.js';

import * as ioTs from 'io-ts';
import * as fpTs from 'fp-ts';
import { pipe } from 'fp-ts/function';
import * as O from 'fp-ts/Option';
import * as E from 'fp-ts/Either';

import { createIntl, createIntlCache } from '@formatjs/intl';
import '@formatjs/intl-locale/polyfill';
import '@formatjs/intl-pluralrules/polyfill';
import '@formatjs/intl-numberformat/polyfill';
import '@formatjs/intl-datetimeformat/polyfill';

void db; void storage; void functions; void remoteConfig; void dynamicLinks; void perf;
void appCheck; void iam; void installations;
void StripeProvider; void useStripe; void useConfirmPayment;
void Dropdown; void Snackbar; void MibSlider; void Share;
void ReactQueryDevtools; void QueryCache; void MutationCache;
void ReactNativeHapticFeedback; void RNBootSplash; void DeviceInfo;
void DocumentPicker; void EncryptedStorage; void RSA;
void ethers; void BrowserProvider; void Wallet; void JsonRpcProvider; void parseEther; void formatEther;
void Connection; void PublicKey; void Keypair; void LAMPORTS_PER_SOL; void SystemProgram;
void ioTs; void fpTs; void pipe; void O; void E;
void createIntl; void createIntlCache;

// --- batch 5: three.js / charts / rich text / files / sockets / analytics / virtualization
import * as THREE from 'three';
import * as glMatrix from 'gl-matrix';

import { useReactTable, getCoreRowModel, getSortedRowModel, getFilteredRowModel, getPaginationRowModel } from '@tanstack/react-table';
import { useVirtualizer, useWindowVirtualizer } from '@tanstack/react-virtual';

import { LineChart as RcLine, BarChart as RcBar, PieChart as RcPie, AreaChart as RcArea, ResponsiveContainer } from 'recharts';
import { Chart as ChartJS, registerables } from 'chart.js';
import { Line as Chart2Line, Bar as Chart2Bar, Pie as Chart2Pie } from 'react-chartjs-2';

import { EditorState } from 'prosemirror-state';
import { EditorView } from 'prosemirror-view';
import { Schema, DOMParser, Node as PmNode } from 'prosemirror-model';
import * as pmTransform from 'prosemirror-transform';
import * as pmSchemaBasic from 'prosemirror-schema-basic';
import * as pmSchemaList from 'prosemirror-schema-list';
import * as pmCommands from 'prosemirror-commands';
import * as pmKeymap from 'prosemirror-keymap';
import * as pmHistory from 'prosemirror-history';
import * as pmDropCursor from 'prosemirror-dropcursor';
import * as pmGapCursor from 'prosemirror-gapcursor';
import * as pmInputRules from 'prosemirror-inputrules';
import * as pmMenu from 'prosemirror-menu';

import { Editor as TiptapEditor } from '@tiptap/core';
import { useEditor, EditorContent } from '@tiptap/react';
import { StarterKit } from '@tiptap/starter-kit';
import Link from '@tiptap/extension-link';
import Image from '@tiptap/extension-image';
import Table from '@tiptap/extension-table';
import TaskList from '@tiptap/extension-task-list';

import * as XLSX from 'xlsx';
import jsPDF from 'jspdf';
import * as pdfMake from 'pdfmake/build/pdfmake';
import html2canvas from 'html2canvas';

import { io as socketIO } from 'socket.io-client';
import { HubConnectionBuilder, LogLevel } from '@microsoft/signalr';

import Mixpanel from 'mixpanel-react-native';
import algoliasearch from 'algoliasearch';

import { AutoSizer, List as VListLib, Grid as VGridLib } from 'react-virtualized';
import { FixedSizeList, VariableSizeList } from 'react-window';

import * as fabric from 'fabric';
import Konva from 'konva';

import { ResponsiveLine } from '@nivo/line';
import { ResponsiveBar } from '@nivo/bar';
import { ResponsivePie } from '@nivo/pie';
import { ResponsiveScatterPlot } from '@nivo/scatterplot';

void THREE; void glMatrix;
void useReactTable; void getCoreRowModel; void getSortedRowModel; void getFilteredRowModel; void getPaginationRowModel;
void useVirtualizer; void useWindowVirtualizer;
void RcLine; void RcBar; void RcPie; void RcArea; void ResponsiveContainer;
void ChartJS; void registerables; void Chart2Line; void Chart2Bar; void Chart2Pie;
void EditorState; void EditorView; void Schema; void DOMParser; void PmNode;
void pmTransform; void pmSchemaBasic; void pmSchemaList; void pmCommands; void pmKeymap; void pmHistory;
void pmDropCursor; void pmGapCursor; void pmInputRules; void pmMenu;
void TiptapEditor; void useEditor; void EditorContent; void StarterKit;
void Link; void Image; void Table; void TaskList;
void XLSX; void jsPDF; void pdfMake; void html2canvas;
void socketIO; void HubConnectionBuilder; void LogLevel;
void Mixpanel; void algoliasearch;
void AutoSizer; void VListLib; void VGridLib;
void FixedSizeList; void VariableSizeList;
void fabric; void Konva;
void ResponsiveLine; void ResponsiveBar; void ResponsivePie; void ResponsiveScatterPlot;

// Reference markers (batch 2)
void AsyncStorage;
void Sentry;
void firebase; void auth; void firestore; void analytics; void messaging; void crashlytics;
void PaperProvider; void Button; void Card; void Appbar; void PaperInput;
void TabView; void SceneMap; void PagerView;
void notifee;
void RNIap; void Keychain;
void RNConfig; void RNLocalize; void i18n; void useTranslation; void initReactI18next;
void Clipboard; void NetInfo; void DateTimePicker;
void ImagePicker; void Permissions; void FastImage; void LinearGradient; void Modal;
void moment; void R; void produce; void immerable;
void ApolloClient; void ApolloProvider; void gql; void InMemoryCache; void useApolloQuery;
void styled;

// Reference markers — tree-shake 방지
void NavigationContainer;
void createNativeStackNavigator;
void createBottomTabNavigator;
void createDrawerNavigator;
void QueryClient;
void QueryClientProvider;
void useQuery;
void useMutation;
void useInfiniteQuery;
void axios;
void configureStore;
void createSlice;
void createAsyncThunk;
void ReduxProvider;
void useSelector;
void useDispatch;
void persistStore;
void persistReducer;
void useForm;
void Controller;
void FormProvider;
void zodResolver;
void z;
void Formik;
void Form;
void Field;
void yup;
void dfFormat;
void parseISO;
void addDays;
void differenceInDays;
void startOfMonth;
void endOfMonth;
void dayjs;
void _;
void Icon;
void FAIcon;
void Ionicons;
void MMKV;

import React, { useCallback, useEffect, useState } from 'react';
import {
  StatusBar,
  StyleSheet,
  useColorScheme,
  View,
  Text,
  Image,
  TouchableOpacity,
  ScrollView,
  ActivityIndicator,
} from 'react-native';
import { Gesture, GestureDetector, GestureHandlerRootView } from 'react-native-gesture-handler';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  useAnimatedScrollHandler,
  withSpring,
  withTiming,
  withRepeat,
  withSequence,
  withDelay,
  interpolate,
  interpolateColor,
  useDerivedValue,
  FadeIn,
  FadeOut,
  FadeInDown,
  SlideInRight,
  SlideInLeft,
  ZoomIn,
  ZoomOut,
  Layout,
  LinearTransition,
  Extrapolation,
} from 'react-native-reanimated';
import { SafeAreaProvider, useSafeAreaInsets } from 'react-native-safe-area-context';
import CheckIcon from '~/assets/check.svg';
import { getGreeting, getVersion } from '~/utils/greeting';

// ES5 다운레벨 스트레스 테스트 — 번들 출력 검증용. 런타임엔 호출 안 해도 됨.
import { es5DownlevelCases } from './src/es5-downlevel-cases';

const testIcon = require('./src/assets/test-icon.png');
// tree-shake 방지 — 참조만 유지
void es5DownlevelCases;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type TestStatus = 'idle' | 'running' | 'success' | 'error';

interface TestResult {
  status: TestStatus;
  message: string;
  duration?: number;
}

// ---------------------------------------------------------------------------
// Network test helpers
// ---------------------------------------------------------------------------

async function runWithTiming<T>(fn: () => Promise<T>): Promise<{ result: T; duration: number }> {
  const start = Date.now();
  const result = await fn();
  return { result, duration: Date.now() - start };
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

function App() {
  const isDarkMode = useColorScheme() === 'dark';
  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaProvider>
        <StatusBar barStyle={isDarkMode ? 'light-content' : 'dark-content'} />
        <AppContent isDarkMode={isDarkMode} />
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}

function AppContent({ isDarkMode }: { isDarkMode: boolean }) {
  const insets = useSafeAreaInsets();
  const bg = isDarkMode ? '#1a1a2e' : '#f5f5f7';
  const cardBg = isDarkMode ? '#16213e' : '#fff';
  const textColor = isDarkMode ? '#e0e0e0' : '#1c1c1e';
  const dimColor = isDarkMode ? '#8e8e93' : '#8e8e93';

  // Bundler info
  const [bundlerName, setBundlerName] = useState('');
  const [hermesEnabled, setHermesEnabled] = useState(false);

  useEffect(() => {
    const isBungae = (globalThis as any).__BUNGAE_BUNDLER__ === true;
    const ver = (globalThis as any).__BUNGAE_VERSION__;
    setBundlerName(isBungae ? `Bungae${ver ? ' v' + ver : ''}` : 'Metro');
    setHermesEnabled(!!(globalThis as any).HermesInternal);
  }, []);

  // Network test states
  const [fetchGet, setFetchGet] = useState<TestResult>({ status: 'idle', message: '' });
  const [fetchPost, setFetchPost] = useState<TestResult>({ status: 'idle', message: '' });
  const [fetchError, setFetchError] = useState<TestResult>({ status: 'idle', message: '' });
  const [wsTest, setWsTest] = useState<TestResult>({ status: 'idle', message: '' });
  const [timeoutTest, setTimeoutTest] = useState<TestResult>({ status: 'idle', message: '' });
  const [multiTest, setMultiTest] = useState<TestResult>({ status: 'idle', message: '' });
  const [errorTest, setErrorTest] = useState<TestResult>({ status: 'idle', message: '' });
  const [consoleTest, setConsoleTest] = useState<TestResult>({ status: 'idle', message: '' });

  // --- Test: GET ---
  const runFetchGet = useCallback(async () => {
    setFetchGet({ status: 'running', message: 'Fetching...' });
    try {
      const { result: res, duration } = await runWithTiming(() =>
        fetch('https://jsonplaceholder.typicode.com/posts/1'),
      );
      const json = await res.json();
      setFetchGet({
        status: 'success',
        message: `${res.status} OK  |  title: "${(json.title as string).slice(0, 40)}..."`,
        duration,
      });
    } catch (e: any) {
      setFetchGet({ status: 'error', message: e.message });
    }
  }, []);

  // --- Test: POST ---
  const runFetchPost = useCallback(async () => {
    setFetchPost({ status: 'running', message: 'Posting...' });
    try {
      const { result: res, duration } = await runWithTiming(() =>
        fetch('https://jsonplaceholder.typicode.com/posts', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ title: 'bungae-test', body: 'hello', userId: 1 }),
        }),
      );
      const json = await res.json();
      setFetchPost({
        status: 'success',
        message: `${res.status} Created  |  id: ${json.id}`,
        duration,
      });
    } catch (e: any) {
      setFetchPost({ status: 'error', message: e.message });
    }
  }, []);

  // --- Test: Error handling (404) ---
  const runFetchError = useCallback(async () => {
    setFetchError({ status: 'running', message: 'Requesting 404...' });
    try {
      const { result: res, duration } = await runWithTiming(() => fetch('https://httpstat.us/404'));
      setFetchError({
        status: res.ok ? 'success' : 'error',
        message: `${res.status} ${res.statusText || 'Not Found'}`,
        duration,
      });
    } catch (e: any) {
      setFetchError({ status: 'error', message: e.message });
    }
  }, []);

  // --- Test: WebSocket ---
  const runWsTest = useCallback(async () => {
    setWsTest({ status: 'running', message: 'Connecting...' });
    const start = Date.now();
    try {
      const ws = new WebSocket('wss://echo.websocket.org');
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => {
          ws.close();
          reject(new Error('Connection timeout (5s)'));
        }, 5000);

        ws.onopen = () => {
          ws.send('bungae-ping');
        };
        ws.onmessage = (ev) => {
          clearTimeout(timer);
          const duration = Date.now() - start;
          setWsTest({
            status: 'success',
            message: `Echo: "${ev.data}"`,
            duration,
          });
          ws.close();
          resolve();
        };
        ws.onerror = () => {
          clearTimeout(timer);
          reject(new Error('WebSocket error'));
        };
      });
    } catch (e: any) {
      setWsTest({ status: 'error', message: e.message, duration: Date.now() - start });
    }
  }, []);

  // --- Test: Timeout ---
  const runTimeoutTest = useCallback(async () => {
    setTimeoutTest({ status: 'running', message: 'Testing timeout (3s limit)...' });
    const start = Date.now();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 3000);

    try {
      await fetch('https://httpstat.us/200?sleep=10000', { signal: controller.signal });
      clearTimeout(timer);
      setTimeoutTest({
        status: 'success',
        message: 'Completed (unexpected)',
        duration: Date.now() - start,
      });
    } catch (e: any) {
      clearTimeout(timer);
      const duration = Date.now() - start;
      const aborted = e.name === 'AbortError';
      setTimeoutTest({
        status: aborted ? 'success' : 'error',
        message: aborted ? `Aborted after ${duration}ms (correct)` : e.message,
        duration,
      });
    }
  }, []);

  // --- Test: Parallel requests ---
  const runMultiTest = useCallback(async () => {
    setMultiTest({ status: 'running', message: 'Sending 5 parallel requests...' });
    const start = Date.now();
    try {
      const urls = Array.from(
        { length: 5 },
        (_, i) => `https://jsonplaceholder.typicode.com/posts/${i + 1}`,
      );
      const responses = await Promise.all(urls.map((u) => fetch(u)));
      const allOk = responses.every((r) => r.ok);
      const duration = Date.now() - start;
      setMultiTest({
        status: allOk ? 'success' : 'error',
        message: `${responses.length} requests  |  all ${allOk ? 'OK' : 'FAILED'}`,
        duration,
      });
    } catch (e: any) {
      setMultiTest({ status: 'error', message: e.message, duration: Date.now() - start });
    }
  }, []);

  // --- Test: Error (throw) ---
  const runErrorTest = useCallback(() => {
    setErrorTest({ status: 'running', message: 'Throwing error...' });
    try {
      const nested = () => {
        throw new Error('Bungae Error Test: intentional error for Red Screen / LogBox testing');
      };
      nested();
    } catch (e: any) {
      console.error('Error test:', e.message);
      console.error('Stack:', e.stack);
      setErrorTest({
        status: 'error',
        message: `Caught: ${e.message.slice(0, 60)}`,
      });
    }
  }, []);

  // --- Test: Console levels ---
  const runConsoleTest = useCallback(() => {
    setConsoleTest({ status: 'running', message: 'Logging...' });
    console.log('[Bungae] console.log test');
    console.info('[Bungae] console.info test');
    console.warn('[Bungae] console.warn test');
    console.error('[Bungae] console.error test');
    console.debug('[Bungae] console.debug test');

    // Object / Array test
    console.log('Object test:', {
      bundler: 'Bungae',
      version: '0.0.1',
      features: ['HMR', 'Fast Refresh', 'Source Maps'],
      nested: { platform: 'ios', dev: true },
    });
    console.log('Array test:', [1, 'two', { three: 3 }, [4, 5]]);

    // native import + lodash path import test
    console.log('Lodash import test:', getGreeting('world'));
    console.log('Version:', getVersion());

    setConsoleTest({
      status: 'success',
      message: 'Sent 9 logs (5 levels + object + array + alias + lodash) — check terminal',
    });
  }, []);

  // Run all
  const runAll = useCallback(async () => {
    runErrorTest();
    runConsoleTest();
    await Promise.all([
      runFetchGet(),
      runFetchPost(),
      runFetchError(),
      runWsTest(),
      runTimeoutTest(),
      runMultiTest(),
    ]);
  }, [
    runFetchGet,
    runFetchPost,
    runFetchError,
    runWsTest,
    runTimeoutTest,
    runMultiTest,
    runErrorTest,
    runConsoleTest,
  ]);

  return (
    <ScrollView
      style={[styles.root, { backgroundColor: bg }]}
      contentContainerStyle={{ paddingBottom: insets.bottom + 20 }}
    >
      {/* Header */}
      <View style={[styles.header, { paddingTop: insets.top + 12 }]}>
        <Text style={[styles.title, { color: textColor }]}>Bungae</Text>
        <Text style={[styles.subtitle, { color: dimColor }]}>Network Test</Text>
      </View>

      {/* Status badges */}
      <View style={styles.badgeRow}>
        <Badge
          label={bundlerName}
          color={bundlerName.startsWith('Bungae') ? '#f59e0b' : '#3b82f6'}
        />
        <Badge
          label={hermesEnabled ? 'Hermes' : 'JSC'}
          color={hermesEnabled ? '#22c55e' : '#ef4444'}
        />
        <View style={styles.assetBadge}>
          <Image source={testIcon} style={styles.testIcon} />
          <Text style={styles.badgeLabel}>Asset</Text>
        </View>
      </View>

      {/* Reanimated Demos — 최상단에 배치 (런타임 검증용) */}
      <View style={styles.section}>
        <ReanimatedDemo cardBg={cardBg} textColor={textColor} dimColor={dimColor} />
        <DragDemo cardBg={cardBg} textColor={textColor} dimColor={dimColor} />
        <ScrollLinkedDemo cardBg={cardBg} textColor={textColor} dimColor={dimColor} />
        <PinchRotateDemo cardBg={cardBg} textColor={textColor} dimColor={dimColor} />
        <LayoutTransitionDemo cardBg={cardBg} textColor={textColor} dimColor={dimColor} />
        <CustomEnteringDemo cardBg={cardBg} textColor={textColor} dimColor={dimColor} />
        <SharedMorphDemo cardBg={cardBg} textColor={textColor} dimColor={dimColor} />
      </View>

      {/* Run all */}
      <TouchableOpacity onPress={runAll} style={styles.runAllBtn} activeOpacity={0.8}>
        <Text style={styles.runAllText}>Run All Tests</Text>
      </TouchableOpacity>

      {/* Test cards */}
      <View style={styles.section}>
        <TestCard
          title='GET Request'
          desc='jsonplaceholder /posts/1'
          result={fetchGet}
          onRun={runFetchGet}
          cardBg={cardBg}
          textColor={textColor}
          dimColor={dimColor}
        />
        <TestCard
          title='POST Request'
          desc='jsonplaceholder /posts'
          result={fetchPost}
          onRun={runFetchPost}
          cardBg={cardBg}
          textColor={textColor}
          dimColor={dimColor}
        />
        <TestCard
          title='Error Handling'
          desc='httpstat.us/404'
          result={fetchError}
          onRun={runFetchError}
          cardBg={cardBg}
          textColor={textColor}
          dimColor={dimColor}
        />
        <TestCard
          title='WebSocket Echo'
          desc='echo.websocket.org'
          result={wsTest}
          onRun={runWsTest}
          cardBg={cardBg}
          textColor={textColor}
          dimColor={dimColor}
        />
        <TestCard
          title='Abort Timeout'
          desc='3s timeout on 10s delay'
          result={timeoutTest}
          onRun={runTimeoutTest}
          cardBg={cardBg}
          textColor={textColor}
          dimColor={dimColor}
        />
        <TestCard
          title='Parallel Fetch'
          desc='5 concurrent GET requests'
          result={multiTest}
          onRun={runMultiTest}
          cardBg={cardBg}
          textColor={textColor}
          dimColor={dimColor}
        />
        <TestCard
          title='Error / SourceMap'
          desc='Throw error — check Red Screen + stack trace'
          result={errorTest}
          onRun={runErrorTest}
          cardBg={cardBg}
          textColor={textColor}
          dimColor={dimColor}
        />
        <TestCard
          title='Console Levels'
          desc='log, info, warn, error, debug — check terminal'
          result={consoleTest}
          onRun={runConsoleTest}
          cardBg={cardBg}
          textColor={textColor}
          dimColor={dimColor}
        />

        {/* Native Transform Tests */}
        <View style={[styles.card, { backgroundColor: cardBg }]}>
          <Text style={[styles.cardTitle, { color: textColor }]}>Native Transforms</Text>
          <Text style={[styles.cardDesc, { color: dimColor }]}>
            SVG component, lodash path import, worklets
          </Text>
          <View style={{ marginTop: 8, gap: 4 }}>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
              <View style={{ backgroundColor: '#E8F5E9', borderRadius: 8, padding: 8 }}>
                <CheckIcon width={32} height={32} stroke='#4CAF50' strokeWidth={3} />
              </View>
              <Text style={{ color: textColor, fontSize: 14, fontWeight: '600' }}>
                SVG component loaded
              </Text>
            </View>
            <Text style={{ color: textColor, fontSize: 13 }}>greeting: {getGreeting('dev')}</Text>
            <Text style={{ color: textColor, fontSize: 13 }}>version: {getVersion()}</Text>
          </View>
        </View>
      </View>
    </ScrollView>
  );
}

// ---------------------------------------------------------------------------
// Reanimated Demo
// ---------------------------------------------------------------------------

function ReanimatedDemo({
  cardBg,
  textColor,
  dimColor,
}: {
  cardBg: string;
  textColor: string;
  dimColor: string;
}) {
  // 1. Spring bounce + rotation
  const scale = useSharedValue(1);
  const rotation = useSharedValue(0);
  const bounceStyle = useAnimatedStyle(() => ({
    transform: [{ scale: scale.value }, { rotateZ: `${rotation.value}deg` }],
  }));

  // (Drag demo는 DragDemo 컴포넌트로 분리 — 최상위 ScrollView의 Pan 가로챔 회피용)

  // 3. Color interpolation
  const progress = useSharedValue(0);
  const bgColor = useDerivedValue(() =>
    interpolateColor(progress.value, [0, 1], ['#3b82f6', '#ef4444']),
  );
  const colorStyle = useAnimatedStyle(() => ({
    backgroundColor: bgColor.value,
  }));

  // 4. Toggle for layout animation
  const [showExtra, setShowExtra] = useState(false);

  const runAll = () => {
    // Bounce
    scale.value = withSequence(withSpring(1.4, { damping: 4 }), withSpring(1));
    rotation.value = withSequence(
      withTiming(360, { duration: 500 }),
      withTiming(0, { duration: 0 }),
    );
    // Color cycle
    progress.value = withSequence(
      withTiming(1, { duration: 600 }),
      withDelay(200, withTiming(0, { duration: 600 })),
    );
    // Layout toggle
    setShowExtra((v) => !v);
  };

  return (
    <View style={[styles.card, { backgroundColor: cardBg }]}>
      <View style={styles.cardHeader}>
        <View style={{ flex: 1 }}>
          <Text style={[styles.cardTitle, { color: textColor }]}>Reanimated + Gesture</Text>
          <Text style={[styles.cardDesc, { color: dimColor }]}>
            Spring, drag, color interpolation, layout animation
          </Text>
        </View>
        <TouchableOpacity onPress={runAll} style={styles.runBtn} activeOpacity={0.7}>
          <Text style={styles.runBtnText}>Run</Text>
        </TouchableOpacity>
      </View>

      <View
        style={{
          flexDirection: 'row',
          justifyContent: 'space-around',
          alignItems: 'center',
          paddingVertical: 20,
        }}
      >
        {/* Spring + Rotation */}
        <Animated.View
          style={[
            {
              width: 56,
              height: 56,
              borderRadius: 12,
              backgroundColor: '#f59e0b',
              justifyContent: 'center',
              alignItems: 'center',
            },
            bounceStyle,
          ]}
        >
          <Text style={{ fontSize: 20 }}>⚡</Text>
        </Animated.View>

        {/* Color Interpolation */}
        <Animated.View
          style={[
            {
              width: 56,
              height: 56,
              borderRadius: 12,
              justifyContent: 'center',
              alignItems: 'center',
            },
            colorStyle,
          ]}
        >
          <Text style={{ fontSize: 14, color: '#fff', fontWeight: '700' }}>Color</Text>
        </Animated.View>
      </View>

      {/* Layout Animation — Phase 2: .withCallback() auto-worklet */}
      {showExtra && (
        <Animated.View
          entering={SlideInRight.duration(300).withCallback((finished) => {
            'worklet';
            if (finished) {
              console.log('[ZNTC] SlideInRight.withCallback 완료');
            }
          })}
          exiting={FadeOut.duration(200)}
          style={{ backgroundColor: '#6366f1', padding: 12, borderRadius: 8, marginTop: 4 }}
        >
          <Text style={{ color: '#fff', fontSize: 13 }}>
            Layout animation working! (SlideInRight + FadeOut)
          </Text>
        </Animated.View>
      )}
    </View>
  );
}

// ---------------------------------------------------------------------------
// Drag demo — Gesture.Pan with ScrollView coexistence
// ---------------------------------------------------------------------------
// 외부 ScrollView가 Pan 제스처를 가로채지 못하도록 activeOffsetX/Y 경계를 좁게 두고
// 첫 포인터 다운 즉시 활성화되도록 minDistance(0) 설정.
function DragDemo({
  cardBg,
  textColor,
  dimColor,
}: {
  cardBg: string;
  textColor: string;
  dimColor: string;
}) {
  const translateX = useSharedValue(0);
  const translateY = useSharedValue(0);

  const dragStyle = useAnimatedStyle(() => ({
    transform: [{ translateX: translateX.value }, { translateY: translateY.value }],
  }));

  const dragGesture = Gesture.Pan()
    .minDistance(0)
    .activeOffsetX([-5, 5])
    .activeOffsetY([-5, 5])
    .onUpdate((e) => {
      translateX.value = e.translationX;
      translateY.value = e.translationY;
    })
    .onEnd(() => {
      translateX.value = withSpring(0);
      translateY.value = withSpring(0);
    });

  return (
    <View style={[styles.card, { backgroundColor: cardBg }]}>
      <View style={styles.cardHeader}>
        <View style={{ flex: 1 }}>
          <Text style={[styles.cardTitle, { color: textColor }]}>Drag</Text>
          <Text style={[styles.cardDesc, { color: dimColor }]}>
            Gesture.Pan — drop 시 withSpring으로 원위치 복귀
          </Text>
        </View>
      </View>
      <View style={{ height: 160, alignItems: 'center', justifyContent: 'center' }}>
        <GestureDetector gesture={dragGesture}>
          <Animated.View
            style={[
              {
                width: 80,
                height: 80,
                borderRadius: 40,
                backgroundColor: '#22c55e',
                justifyContent: 'center',
                alignItems: 'center',
              },
              dragStyle,
            ]}
          >
            <Text style={{ color: '#fff', fontWeight: '700' }}>Drag me</Text>
          </Animated.View>
        </GestureDetector>
      </View>
    </View>
  );
}

// ---------------------------------------------------------------------------
// Scroll-linked animation — useAnimatedScrollHandler + interpolate
// ---------------------------------------------------------------------------
function ScrollLinkedDemo({
  cardBg,
  textColor,
  dimColor,
}: {
  cardBg: string;
  textColor: string;
  dimColor: string;
}) {
  const scrollY = useSharedValue(0);

  const scrollHandler = useAnimatedScrollHandler({
    onScroll: (e) => {
      scrollY.value = e.contentOffset.y;
    },
  });

  const headerStyle = useAnimatedStyle(() => {
    const h = interpolate(scrollY.value, [0, 120], [80, 40], Extrapolation.CLAMP);
    const op = interpolate(scrollY.value, [0, 120], [1, 0.5], Extrapolation.CLAMP);
    return { height: h, opacity: op };
  });

  return (
    <View style={[styles.card, { backgroundColor: cardBg }]}>
      <View style={styles.cardHeader}>
        <View style={{ flex: 1 }}>
          <Text style={[styles.cardTitle, { color: textColor }]}>Scroll-linked Animation</Text>
          <Text style={[styles.cardDesc, { color: dimColor }]}>
            useAnimatedScrollHandler + interpolate (헤더 축소)
          </Text>
        </View>
      </View>
      <Animated.View
        style={[
          {
            borderRadius: 8,
            backgroundColor: '#0ea5e9',
            justifyContent: 'center',
            alignItems: 'center',
            marginBottom: 8,
          },
          headerStyle,
        ]}
      >
        <Text style={{ color: '#fff', fontWeight: '700' }}>Scroll below ⬇</Text>
      </Animated.View>
      <Animated.ScrollView
        onScroll={scrollHandler}
        scrollEventThrottle={16}
        style={{ height: 120, backgroundColor: '#f1f5f9', borderRadius: 8 }}
        contentContainerStyle={{ padding: 12 }}
      >
        {Array.from({ length: 20 }).map((_, i) => (
          <Text key={i} style={{ paddingVertical: 4, color: '#334155' }}>
            item {i + 1}
          </Text>
        ))}
      </Animated.ScrollView>
    </View>
  );
}

// ---------------------------------------------------------------------------
// Pinch + Rotate composed gestures (Gesture.Simultaneous)
// ---------------------------------------------------------------------------
function PinchRotateDemo({
  cardBg,
  textColor,
  dimColor,
}: {
  cardBg: string;
  textColor: string;
  dimColor: string;
}) {
  const scale = useSharedValue(1);
  const savedScale = useSharedValue(1);
  const angle = useSharedValue(0);
  const savedAngle = useSharedValue(0);

  const pinch = Gesture.Pinch()
    .onUpdate((e) => {
      scale.value = savedScale.value * e.scale;
    })
    .onEnd(() => {
      savedScale.value = scale.value;
    });

  const rotate = Gesture.Rotation()
    .onUpdate((e) => {
      angle.value = savedAngle.value + e.rotation;
    })
    .onEnd(() => {
      savedAngle.value = angle.value;
    });

  const composed = Gesture.Simultaneous(pinch, rotate);

  const boxStyle = useAnimatedStyle(() => ({
    transform: [{ scale: scale.value }, { rotateZ: `${(angle.value * 180) / Math.PI}deg` }],
  }));

  const reset = () => {
    scale.value = withSpring(1);
    savedScale.value = 1;
    angle.value = withSpring(0);
    savedAngle.value = 0;
  };

  return (
    <View style={[styles.card, { backgroundColor: cardBg }]}>
      <View style={styles.cardHeader}>
        <View style={{ flex: 1 }}>
          <Text style={[styles.cardTitle, { color: textColor }]}>Pinch + Rotate</Text>
          <Text style={[styles.cardDesc, { color: dimColor }]}>
            두 제스처를 Simultaneous로 합성 (두 손가락으로 조작)
          </Text>
        </View>
        <TouchableOpacity onPress={reset} style={styles.runBtn} activeOpacity={0.7}>
          <Text style={styles.runBtnText}>Reset</Text>
        </TouchableOpacity>
      </View>
      <View style={{ alignItems: 'center', paddingVertical: 24 }}>
        <GestureDetector gesture={composed}>
          <Animated.View
            style={[
              {
                width: 100,
                height: 100,
                borderRadius: 16,
                backgroundColor: '#a855f7',
                justifyContent: 'center',
                alignItems: 'center',
              },
              boxStyle,
            ]}
          >
            <Text style={{ color: '#fff', fontWeight: '700' }}>Pinch/Rot</Text>
          </Animated.View>
        </GestureDetector>
      </View>
    </View>
  );
}

// ---------------------------------------------------------------------------
// Layout transition — 리스트 아이템 add/remove with LinearTransition
// ---------------------------------------------------------------------------
function LayoutTransitionDemo({
  cardBg,
  textColor,
  dimColor,
}: {
  cardBg: string;
  textColor: string;
  dimColor: string;
}) {
  const [items, setItems] = useState<number[]>([1, 2, 3]);

  const add = () => {
    setItems((prev) => [...prev, prev.length > 0 ? Math.max(...prev) + 1 : 1]);
  };
  const remove = (id: number) => {
    setItems((prev) => prev.filter((i) => i !== id));
  };
  const shuffle = () => {
    setItems((prev) => [...prev].sort(() => Math.random() - 0.5));
  };

  return (
    <View style={[styles.card, { backgroundColor: cardBg }]}>
      <View style={styles.cardHeader}>
        <View style={{ flex: 1 }}>
          <Text style={[styles.cardTitle, { color: textColor }]}>Layout Transition</Text>
          <Text style={[styles.cardDesc, { color: dimColor }]}>
            LinearTransition + FadeIn/FadeOut — add/remove/shuffle
          </Text>
        </View>
      </View>
      <View style={{ flexDirection: 'row', gap: 8, marginBottom: 12 }}>
        <TouchableOpacity onPress={add} style={styles.smallBtn}>
          <Text style={styles.smallBtnText}>+ Add</Text>
        </TouchableOpacity>
        <TouchableOpacity onPress={shuffle} style={styles.smallBtn}>
          <Text style={styles.smallBtnText}>Shuffle</Text>
        </TouchableOpacity>
      </View>
      {items.map((id) => (
        <Animated.View
          key={id}
          entering={FadeInDown.duration(300)}
          exiting={FadeOut.duration(200)}
          layout={LinearTransition.springify()}
          style={{
            backgroundColor: '#14b8a6',
            padding: 12,
            borderRadius: 8,
            marginBottom: 6,
            flexDirection: 'row',
            alignItems: 'center',
            justifyContent: 'space-between',
          }}
        >
          <Text style={{ color: '#fff', fontWeight: '600' }}>item #{id}</Text>
          <TouchableOpacity onPress={() => remove(id)}>
            <Text style={{ color: '#fff', fontSize: 18 }}>×</Text>
          </TouchableOpacity>
        </Animated.View>
      ))}
    </View>
  );
}

// ---------------------------------------------------------------------------
// Custom entering animation — initialValues + animations builder
// ---------------------------------------------------------------------------
function CustomEnteringDemo({
  cardBg,
  textColor,
  dimColor,
}: {
  cardBg: string;
  textColor: string;
  dimColor: string;
}) {
  const [key, setKey] = useState(0);

  // Custom entering: scale 0 + rotate -180 → scale 1 + rotate 0, 순차 애니메이션.
  // (이 함수 자체가 UI 스레드에서 실행되는 worklet — 'worklet' 디렉티브 필수)
  const customEntering = (values: { targetWidth: number; targetHeight: number }) => {
    'worklet';
    const animations = {
      transform: [
        { scale: withSpring(1, { damping: 8 }) },
        { rotateZ: withTiming('0deg', { duration: 500 }) },
      ],
      opacity: withTiming(1, { duration: 400 }),
    };
    const initialValues = {
      transform: [{ scale: 0 }, { rotateZ: '-180deg' }],
      opacity: 0,
    };
    return { initialValues, animations };
  };

  return (
    <View style={[styles.card, { backgroundColor: cardBg }]}>
      <View style={styles.cardHeader}>
        <View style={{ flex: 1 }}>
          <Text style={[styles.cardTitle, { color: textColor }]}>Custom Entering</Text>
          <Text style={[styles.cardDesc, { color: dimColor }]}>
            initialValues + animations worklet builder
          </Text>
        </View>
        <TouchableOpacity
          onPress={() => setKey((k) => k + 1)}
          style={styles.runBtn}
          activeOpacity={0.7}
        >
          <Text style={styles.runBtnText}>Replay</Text>
        </TouchableOpacity>
      </View>
      <View style={{ alignItems: 'center', paddingVertical: 24 }}>
        <Animated.View
          key={key}
          entering={customEntering}
          exiting={ZoomOut.duration(200)}
          style={{
            width: 80,
            height: 80,
            borderRadius: 40,
            backgroundColor: '#ec4899',
            justifyContent: 'center',
            alignItems: 'center',
          }}
        >
          <Text style={{ color: '#fff', fontWeight: '700' }}>★</Text>
        </Animated.View>
      </View>
    </View>
  );
}

// ---------------------------------------------------------------------------
// Shared morph — 하나의 element를 두 레이아웃 사이로 전환
// ---------------------------------------------------------------------------
function SharedMorphDemo({
  cardBg,
  textColor,
  dimColor,
}: {
  cardBg: string;
  textColor: string;
  dimColor: string;
}) {
  const [expanded, setExpanded] = useState(false);

  const progress = useDerivedValue(() => withSpring(expanded ? 1 : 0, { damping: 14 }));

  const morphStyle = useAnimatedStyle(() => {
    const p = progress.value;
    return {
      width: interpolate(p, [0, 1], [80, 240]),
      height: interpolate(p, [0, 1], [80, 120]),
      borderRadius: interpolate(p, [0, 1], [40, 16]),
      backgroundColor: interpolateColor(p, [0, 1], ['#f97316', '#0ea5e9']),
    };
  });

  const labelStyle = useAnimatedStyle(() => ({
    opacity: progress.value,
  }));

  return (
    <View style={[styles.card, { backgroundColor: cardBg }]}>
      <View style={styles.cardHeader}>
        <View style={{ flex: 1 }}>
          <Text style={[styles.cardTitle, { color: textColor }]}>Shared Morph</Text>
          <Text style={[styles.cardDesc, { color: dimColor }]}>
            derived spring + interpolate로 크기/색/반경 동시 전환
          </Text>
        </View>
        <TouchableOpacity
          onPress={() => setExpanded((v) => !v)}
          style={styles.runBtn}
          activeOpacity={0.7}
        >
          <Text style={styles.runBtnText}>Toggle</Text>
        </TouchableOpacity>
      </View>
      <View style={{ alignItems: 'center', paddingVertical: 20 }}>
        <Animated.View style={[{ justifyContent: 'center', alignItems: 'center' }, morphStyle]}>
          <Animated.Text style={[{ color: '#fff', fontWeight: '700' }, labelStyle]}>
            expanded
          </Animated.Text>
        </Animated.View>
      </View>
    </View>
  );
}

// =============================================================================
// ZNTC Worklet Parity Demos — Phase별 AST 변환 시연
// =============================================================================
// 각 예제는 빌드 시 ZNTC가 워크릿 변환을 올바르게 적용하는지 확인하기 위한 샘플.
// 런타임 실행 여부는 Reanimated runtime 통합에 따라 다름.

// Phase 4: class field arrow worklet
class WorkletHelper {
  multiplier = (x: number) => {
    'worklet';
    return x * 2;
  };
}

// Phase 3: object method worklet (class getter/setter는 TS private field와 간섭하므로
// 여기선 object literal 형태로 시연 — 동일한 method_definition 경로 사용)
const WorkletMethodHolder = {
  describe(x: number) {
    'worklet';
    return 'value=' + x;
  },
};

// Phase 5: __workletClass marker → <Class>__classFactory 자동 생성
class WorkletMarkedClass {
  __workletClass = true;
  sayHello() {
    return 'hi from worklet class';
  }
}

// Phase 6.5: __workletContextObject marker → context factory
const WorkletContextHolder = {
  add(a: number, b: number) {
    return a + b;
  },
  __workletContextObject: true,
};

// Phase 6.4: implicit context object via file-level directive는 별도 파일에서 (런타임
// 테스트 대상 아닌 구조 검증 목적). App.tsx 자체는 file-level directive 미적용.

// 참조 마커 (트리셰이킹 방지)
void WorkletHelper;
void WorkletMethodHolder;
void WorkletMarkedClass;
void WorkletContextHolder;

// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------

function Badge({ label, color }: { label: string; color: string }) {
  return (
    <View style={[styles.badge, { backgroundColor: color }]}>
      <Text style={styles.badgeLabel}>{label}</Text>
    </View>
  );
}

function TestCard({
  title,
  desc,
  result,
  onRun,
  cardBg,
  textColor,
  dimColor,
}: {
  title: string;
  desc: string;
  result: TestResult;
  onRun: () => void;
  cardBg: string;
  textColor: string;
  dimColor: string;
}) {
  const statusColor =
    result.status === 'success'
      ? '#22c55e'
      : result.status === 'error'
        ? '#ef4444'
        : result.status === 'running'
          ? '#3b82f6'
          : dimColor;

  return (
    <View style={[styles.card, { backgroundColor: cardBg }]}>
      <View style={styles.cardHeader}>
        <View style={{ flex: 1 }}>
          <Text style={[styles.cardTitle, { color: textColor }]}>{title}</Text>
          <Text style={[styles.cardDesc, { color: dimColor }]}>{desc}</Text>
        </View>
        <TouchableOpacity
          onPress={onRun}
          style={[styles.runBtn, result.status === 'running' && styles.runBtnDisabled]}
          activeOpacity={0.7}
          disabled={result.status === 'running'}
        >
          {result.status === 'running' ? (
            <ActivityIndicator size='small' color='#fff' />
          ) : (
            <Text style={styles.runBtnText}>Run</Text>
          )}
        </TouchableOpacity>
      </View>

      {result.status !== 'idle' && (
        <View style={[styles.resultRow, { borderTopColor: dimColor + '22' }]}>
          <View style={[styles.statusDot, { backgroundColor: statusColor }]} />
          <Text style={[styles.resultText, { color: textColor }]} numberOfLines={2}>
            {result.message}
          </Text>
          {result.duration != null && (
            <Text style={[styles.durationText, { color: dimColor }]}>{result.duration}ms</Text>
          )}
        </View>
      )}
    </View>
  );
}

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const styles = StyleSheet.create({
  root: {
    flex: 1,
  },
  header: {
    paddingHorizontal: 20,
    paddingBottom: 8,
  },
  title: {
    fontSize: 34,
    fontWeight: '800',
    letterSpacing: -0.5,
  },
  subtitle: {
    fontSize: 17,
    fontWeight: '400',
    marginTop: 2,
  },
  badgeRow: {
    flexDirection: 'row',
    paddingHorizontal: 20,
    gap: 8,
    marginTop: 12,
  },
  badge: {
    paddingHorizontal: 12,
    paddingVertical: 5,
    borderRadius: 14,
  },
  badgeLabel: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '600',
  },
  assetBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#6366f1',
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 14,
    gap: 4,
  },
  testIcon: {
    width: 18,
    height: 18,
  },
  runAllBtn: {
    marginHorizontal: 20,
    marginTop: 20,
    backgroundColor: '#007AFF',
    paddingVertical: 14,
    borderRadius: 12,
    alignItems: 'center',
  },
  runAllText: {
    color: '#fff',
    fontSize: 17,
    fontWeight: '700',
  },
  section: {
    paddingHorizontal: 20,
    marginTop: 16,
    gap: 10,
  },
  card: {
    borderRadius: 12,
    padding: 14,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.08,
    shadowRadius: 4,
    elevation: 2,
  },
  cardHeader: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  cardTitle: {
    fontSize: 16,
    fontWeight: '600',
  },
  cardDesc: {
    fontSize: 13,
    marginTop: 1,
  },
  runBtn: {
    backgroundColor: '#007AFF',
    paddingHorizontal: 18,
    paddingVertical: 8,
    borderRadius: 8,
    minWidth: 60,
    alignItems: 'center',
  },
  runBtnDisabled: {
    backgroundColor: '#007AFF88',
  },
  runBtnText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '600',
  },
  smallBtn: {
    backgroundColor: '#64748b',
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 6,
  },
  smallBtnText: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '600',
  },
  resultRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginTop: 10,
    paddingTop: 10,
    borderTopWidth: StyleSheet.hairlineWidth,
    gap: 8,
  },
  statusDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
  },
  resultText: {
    flex: 1,
    fontSize: 13,
  },
  durationText: {
    fontSize: 12,
    fontWeight: '500',
  },
});

export default App;
