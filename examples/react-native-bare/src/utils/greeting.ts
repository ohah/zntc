import _ from 'lodash';

/**
 * Test module for babel-plugin-root-import (~/utils/greeting)
 * and babel-plugin-lodash (tree-shaking)
 */
export function getGreeting(name: string): string {
  return _.capitalize(`hello ${name} from bungae`);
}

export function getVersion(): string {
  return '1.0.0';
}
