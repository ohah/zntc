import capitalize from 'lodash/capitalize';

/**
 * Test module for direct lodash path import without Babel.
 */
export function getGreeting(name: string): string {
  return capitalize(`hello ${name} from bungae`);
}

export function getVersion(): string {
  return '1.0.0';
}
