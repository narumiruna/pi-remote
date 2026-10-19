// Explicit test-only preload. Production CLI startup and OS-store tests do not load this file.
import { OSSecrets } from "../host/secrets.ts"

const stores = new Map<string, Map<string, Buffer>>()
function values(service: string): Map<string, Buffer> {
  let store = stores.get(service)
  if (!store) {
    store = new Map()
    stores.set(service, store)
  }
  return store
}
OSSecrets.prototype.get = async function (account) {
  const data = values(this.service).get(account)
  return data ? Buffer.from(data) : null
}
OSSecrets.prototype.put = async function (account, data) {
  values(this.service).set(account, Buffer.from(data))
}
OSSecrets.prototype.remove = async function (account) {
  values(this.service).delete(account)
}
