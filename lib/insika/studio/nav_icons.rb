# frozen_string_literal: true

module Studio
  # Nav SVG icons for the Studio App. A mixin included into App: the
  # `nav_icon` view helper and its icon table, moved verbatim out of app.rb.
  # Inline SVG is CSP-safe (an HTML element, not an external resource).
  module NavIcons
    # 20×20 stroke icons (currentColor), one per nav key. Source: a Lucide-style
    # line icon set.
    NAV_ICONS = {
      home: '<path d="M3 9.5 12 3l9 6.5"/><path d="M5 10v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V10"/><path d="M9 21v-6h6v6"/>',
      agents: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
      skills: '<path d="m12 3-1.9 5.8a2 2 0 0 1-1.3 1.3L3 12l5.8 1.9a2 2 0 0 1 1.3 1.3L12 21l1.9-5.8a2 2 0 0 1 1.3-1.3L21 12l-5.8-1.9a2 2 0 0 1-1.3-1.3z"/>',
      tools: '<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>',
      system: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M8 13h8"/><path d="M8 17h8"/>',
      mcp: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/>',
      settings: '<path d="M20 7h-9"/><path d="M14 17H5"/><circle cx="17" cy="17" r="3"/><circle cx="7" cy="7" r="3"/>',
      chats: '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
      playground: '<polygon points="6 3 20 12 6 21 6 3"/>',
      tasks: '<path d="M11 12H3"/><path d="M16 6H3"/><path d="M16 18H3"/><path d="m18 9 3 3-3 3"/>',
      approvals: '<path d="M9 12l2 2 4-4"/><path d="M12 3a9 9 0 1 0 9 9"/>',
      refinement: '<path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 3v5h-5"/><path d="m9 12 2 2 4-4"/>',
      evals: '<path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/>',
      parity: '<path d="M7 21h10"/><path d="M12 3v12"/><path d="m8 11 4 4 4-4"/><path d="M3 17h4l1.5-1.5L6 13 3 15.5z"/><path d="M21 17h-4l-1.5-1.5L18 13l3 2.5z"/>',
      funnel: '<path d="M3 5h18l-8 9v6l-2 1v-7z"/>',
      followups: '<path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/>',
      facts: '<path d="M7 3h11a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H7z"/><path d="M7 3v18"/><path d="M11 8h5"/><path d="M11 12h5"/><path d="M11 16h3"/>',
      harvest: '<path d="M4 20V10"/><path d="M20 20V4"/><path d="M4 10h4v10"/><path d="M20 4h-4v16"/><path d="M4 20h16"/><path d="m8 8 4-4 4 4"/>',
      artifacts: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="m9.5 13 2 2 3.5-3.5"/><path d="M12 15v-4"/>'
    }.freeze

    def nav_icon(key)
      %(<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" ) +
        %(stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">#{NAV_ICONS[key]}</svg>)
    end
  end
end
