import { Controller } from "@hotwired/stimulus"

// agent-picker — type-to-search combobox over agent ids (_agent_picker.erb).
// The input IS the submitted field; the list only helps fill it, so without
// JS the list stays hidden and a typed id still submits (the server validates).
//
// Markup contract:
//   <div data-controller="agent-picker" data-action="focusout->agent-picker#leave">
//     <input data-agent-picker-target="input" data-action="focus->agent-picker#open
//            input->agent-picker#type keydown->agent-picker#key search->agent-picker#cleared">
//     <div data-agent-picker-target="list" hidden data-action="mousedown->agent-picker#hold">
//       <button data-agent-picker-target="option" data-value="id"
//               data-action="click->agent-picker#choose">…</button>
//       <div data-agent-picker-target="empty" hidden>…</div>
//     </div>
//   </div>
export default class extends Controller {
  static targets = ["input", "list", "option", "empty"]
  static values = { autoSubmit: Boolean }

  // Focus shows every agent: the current value is a pick, not a query, until
  // the person types.
  open() {
    this.typed = false
    this.show()
  }

  type() {
    this.typed = true
    this.show()
  }

  show() {
    this.filter()
    this.listTarget.hidden = false
    this.inputTarget.setAttribute("aria-expanded", "true")
  }

  close() {
    this.listTarget.hidden = true
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.move(-1)
  }

  filter() {
    const value = this.inputTarget.value
    const q = this.typed ? value.trim().toLowerCase() : ""
    let shown = 0
    this.optionTargets.forEach((el) => {
      const id = el.dataset.value
      // The "all" row (empty value) only makes sense before a query.
      const match = q === "" || (id !== "" && id.toLowerCase().includes(q))
      el.hidden = !match
      el.setAttribute("aria-selected", String(id === value))
      if (match) shown++
    })
    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown !== 0
    this.move(-1)
  }

  key(event) {
    const open = !this.listTarget.hidden
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      if (!open) this.open()
      this.move(this.active + (event.key === "ArrowDown" ? 1 : -1))
    } else if (event.key === "Enter" && open && this.active >= 0) {
      event.preventDefault() // pick, don't submit the half-typed text
      this.pick(this.visible()[this.active])
    } else if (event.key === "Escape" && open) {
      event.preventDefault()
      this.close()
    }
  }

  choose(event) {
    this.pick(event.currentTarget)
  }

  pick(option) {
    this.inputTarget.value = option.dataset.value
    this.close()
    this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
    if (this.autoSubmitValue) this.inputTarget.form.requestSubmit()
  }

  // The search box's own clear (×) means "all agents" on a filter.
  cleared() {
    if (this.inputTarget.value === "" && this.autoSubmitValue) this.inputTarget.form.requestSubmit()
  }

  // Clicking an option must not blur the input first (that would close the list).
  hold(event) {
    event.preventDefault()
  }

  leave(event) {
    if (!this.element.contains(event.relatedTarget)) this.close()
  }

  visible() {
    return this.optionTargets.filter((el) => !el.hidden)
  }

  move(index) {
    const options = this.visible()
    this.active = options.length === 0 || index < 0 ? -1 : Math.min(index, options.length - 1)
    this.optionTargets.forEach((el) => el.classList.remove("active"))
    const current = options[this.active]
    if (current) {
      current.classList.add("active")
      current.scrollIntoView?.({ block: "nearest" })
      this.inputTarget.setAttribute("aria-activedescendant", current.id)
    } else {
      this.inputTarget.removeAttribute("aria-activedescendant")
    }
  }
}
