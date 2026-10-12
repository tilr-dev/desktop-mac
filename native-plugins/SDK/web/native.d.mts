export interface NativeProvider {
  id: string
  version: string
  channels: string[]
  events: string[]
}
export function connectNative(options?: { window?: Window, timeout?: number }): {
  describe(): Promise<NativeProvider[]>
  send(plugin: string, channel: string, message: Record<string, unknown>): Promise<{ accepted: true }>
  on(event: string, listener: (detail: Record<string, unknown>) => void): () => void
  dispose(): void
}
