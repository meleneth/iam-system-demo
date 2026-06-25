import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["partition", "filter", "results", "count", "status"]
  static values = { visibleLimit: { type: Number, default: 750 } }

  connect() {
    this.usersById = new Map()
    this.accountsById = new Map()
    this.processedPartitions = new WeakSet()
    this.loadedPartitions = 0
    this.totalAccounts = null
    this.render()
  }

  partitionTargetConnected(element) {
    if (this.processedPartitions.has(element)) return
    this.processedPartitions.add(element)

    const payload = JSON.parse(element.textContent)
    if (payload.loading) {
      this.setStatus(payload.message || "Preparing access")
      this.retryPartition(element, payload)
      return
    }

    for (const account of payload.accounts || []) {
      this.accountsById.set(String(account.id), account)
    }

    for (const user of payload.users || []) {
      const account = user.account || this.accountsById.get(String(user.account_id)) || {}
      const groups = user.groups || []
      this.usersById.set(String(user.id), {
        id: String(user.id),
        email: user.email || "",
        username: user.username || "",
        firstName: user.first_name || "",
        lastName: user.last_name || "",
        accountId: String(user.account_id || account.id || ""),
        accountName: account.name || "",
        groups: groups.map((group) => ({
          id: String(group.id),
          name: group.name || ""
        }))
      })
    }

    this.loadedPartitions += 1
    this.totalAccounts = payload.total_account_count ?? this.totalAccounts
    this.setStatus(this.statusText(payload))
    this.render()
  }

  filter() {
    this.render()
  }

  clear() {
    this.filterTarget.value = ""
    this.render()
    this.filterTarget.focus()
  }

  render() {
    if (!this.hasResultsTarget) return

    const query = (this.hasFilterTarget ? this.filterTarget.value : "").trim().toLowerCase()
    const users = Array.from(this.usersById.values())
    const filtered = query ? users.filter((user) => this.matches(user, query)) : users
    const visible = filtered.slice(0, this.visibleLimitValue)

    this.resultsTarget.replaceChildren(...visible.map((user) => this.rowFor(user)))
    this.setCount(filtered.length, users.length, visible.length)
  }

  matches(user, query) {
    const haystack = [
      user.id,
      user.email,
      user.username,
      user.firstName,
      user.lastName,
      user.accountId,
      user.accountName,
      ...user.groups.flatMap((group) => [group.id, group.name])
    ].join(" ").toLowerCase()

    return haystack.includes(query)
  }

  rowFor(user) {
    const row = document.createElement("tr")
    row.className = "border-t border-gray-200 dark:border-gray-700"

    row.append(
      this.cell(user.id, "font-mono text-xs"),
      this.cell([user.accountName, user.accountId].filter(Boolean).join(" ") || user.accountId, "font-mono text-xs"),
      this.cell(user.email || user.username || "-"),
      this.cell(user.groups.map((group) => group.name || group.id).join(", ") || "-")
    )

    return row
  }

  cell(text, extraClasses = "") {
    const cell = document.createElement("td")
    cell.className = `px-3 py-2 align-top ${extraClasses}`
    cell.textContent = text
    return cell
  }

  setCount(filteredCount, totalCount, visibleCount) {
    if (!this.hasCountTarget) return

    const hidden = filteredCount - visibleCount
    this.countTarget.textContent = hidden > 0
      ? `${visibleCount} shown of ${filteredCount} matching, ${totalCount} loaded`
      : `${filteredCount} shown, ${totalCount} loaded`
  }

  setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }

  retryPartition(element, payload) {
    if (!payload.retry_path) return

    const frame = element.closest("turbo-frame")
    if (!frame) return

    window.setTimeout(() => {
      frame.src = payload.retry_path
    }, payload.retry_after_ms || 1500)
  }

  statusText(payload) {
    const accountText = this.totalAccounts == null
      ? `${payload.partition_account_count || 0} accounts in latest partition`
      : `${this.accountsById.size} / ${this.totalAccounts} accounts loaded`

    return `${accountText}; ${this.usersById.size} users in browser memory`
  }
}
