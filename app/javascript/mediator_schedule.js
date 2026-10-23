function initializeMediatorSchedule() {
  const page = document.getElementById("availability-slots-list");
  if (!page || page.dataset.initialized === "true") return;

  page.dataset.initialized = "true";

  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
  const dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

  async function request(url, options = {}) {
    const response = await fetch(url, {
      ...options,
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        ...options.headers
      }
    });

    if (!response.ok) {
      const data = await response.json().catch(() => ({}));
      throw new Error(data.errors?.join(", ") || data.error || "Request failed");
    }

    return response.status === 204 ? null : response.json();
  }

  function formatTime(value) {
    if (!value) return "";
    const date = new Date(value.includes("T") ? value : `1970-01-01T${value}`);
    return Number.isNaN(date.getTime())
      ? value
      : date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  }

  function formatDateTime(value) {
    return new Date(value).toLocaleString([], {
      month: "short",
      day: "numeric",
      year: "numeric",
      hour: "numeric",
      minute: "2-digit"
    });
  }

  // Weekly availability
  async function loadAvailability() {
    const list = document.getElementById("availability-slots-list");

    try {
      const slots = await request("/mediator_schedule_availabilities");

      list.replaceChildren();

      if (!slots.length) {
        list.textContent = "No regular working hours added yet.";
        return;
      }

      slots.forEach(slot => {
        const row = document.createElement("div");
        row.style.cssText = "display:flex;justify-content:space-between;align-items:center;padding:12px;border-bottom:1px solid #e2e8f0;gap:12px;";

        const label = document.createElement("span");
        label.textContent = `${dayNames[slot.DayOfWeek]}: ${formatTime(slot.StartTime)} – ${formatTime(slot.EndTime)}`;

        const remove = document.createElement("button");
        remove.type = "button";
        remove.className = "schedule-btn schedule-btn-danger";
        remove.textContent = "Remove";

        remove.addEventListener("click", async () => {
          if (!confirm("Remove these working hours?")) return;

          try {
            await request(`/mediator_schedule_availabilities/${slot.id}`, { method: "DELETE" });
            await loadAvailability();
          } catch (error) {
            alert(error.message);
          }
        });

        row.append(label, remove);
        list.appendChild(row);
      });
    } catch (error) {
      list.textContent = `Could not load availability: ${error.message}`;
    }
  }

  document.getElementById("btn-add-avail")?.addEventListener("click", async () => {
    const day = document.getElementById("avail-day").value;
    const start = document.getElementById("avail-start").value;
    const end = document.getElementById("avail-end").value;

    if (!start || !end || end <= start) {
      alert("Please enter a valid start and end time.");
      return;
    }

    try {
      await request("/mediator_schedule_availabilities", {
        method: "POST",
        body: JSON.stringify({
          availability: {
            DayOfWeek: Number(day),
            StartTime: start,
            EndTime: end
          }
        })
      });

      document.getElementById("avail-start").value = "";
      document.getElementById("avail-end").value = "";
      await loadAvailability();
    } catch (error) {
      alert(error.message);
    }
  });

  // Blocked periods
  async function loadBlocks() {
    const list = document.getElementById("blocked-slots-list");

    try {
      const blocks = await request("/mediator_schedule_blocks");

      list.replaceChildren();

      if (!blocks.length) {
        list.textContent = "No blocked periods.";
        return;
      }

      blocks.forEach(block => {
        const row = document.createElement("div");
        row.style.cssText = "display:flex;justify-content:space-between;align-items:center;padding:12px;border-bottom:1px solid #e2e8f0;gap:12px;";

        const label = document.createElement("span");
        label.textContent = `${formatDateTime(block.StartTime)} – ${formatDateTime(block.EndTime)}`;

        const remove = document.createElement("button");
        remove.type = "button";
        remove.className = "btn-secondary";
        remove.textContent = "Remove";

        remove.addEventListener("click", async () => {
          if (!confirm("Remove this blocked period?")) return;

          try {
            await request(`/mediator_schedule_blocks/${block.id}`, { method: "DELETE" });
            await loadBlocks();
          } catch (error) {
            alert(error.message);
          }
        });

        row.append(label, remove);
        list.appendChild(row);
      });
    } catch (error) {
      list.textContent = `Could not load blocked periods: ${error.message}`;
    }
  }

  document.getElementById("btn-add-block")?.addEventListener("click", async () => {
    const start = document.getElementById("block-start").value;
    const end = document.getElementById("block-end").value;

    if (!start || !end || end <= start) {
      alert("Please enter a valid blocked period.");
      return;
    }

    try {
      await request("/mediator_schedule_blocks", {
        method: "POST",
        body: JSON.stringify({
          block: {
            StartTime: start,
            EndTime: end
          }
        })
      });

      document.getElementById("block-start").value = "";
      document.getElementById("block-end").value = "";
      await loadBlocks();
    } catch (error) {
      alert(error.message);
    }
  });

  // Scheduled meetings
  async function loadMeetings() {
    const list = document.getElementById("scheduled-meetings-list");
    const count = document.getElementById("meetings-count");

    try {
      const meetings = await request("/mediator_scheduled_meetings");

      list.replaceChildren();
      count.textContent = `${meetings.length} meetings`;

      if (!meetings.length) {
        list.textContent = "No meetings scheduled.";
        return;
      }

      meetings.forEach(meeting => {
        const row = document.createElement("div");
        row.style.cssText = "display:flex;justify-content:space-between;align-items:center;padding:12px;border-bottom:1px solid #e2e8f0;gap:12px;";

        const label = document.createElement("span");
        label.textContent = `Case #${meeting.ConversationID} — ${formatDateTime(meeting.StartTime)} (${meeting.Status})`;
        row.appendChild(label);

        if (meeting.Status === "scheduled") {
          const cancel = document.createElement("button");
          cancel.type = "button";
          cancel.className = "schedule-btn schedule-btn-danger";
          cancel.textContent = "Cancel Meeting";

          cancel.addEventListener("click", async () => {
            if (!confirm("Cancel this meeting?")) return;

            try {
              await request(`/mediator_scheduled_meetings/${meeting.id}/cancel`, { method: "PATCH" });
              await loadMeetings();
            } catch (error) {
              alert(error.message);
            }
          });

          row.appendChild(cancel);
        }

        list.appendChild(row);
      });
    } catch (error) {
      list.textContent = `Could not load meetings: ${error.message}`;
    }
  }

  // Create mediation meeting
  document.getElementById("btn-create-meeting")?.addEventListener("click", async () => {
    const caseId = document.getElementById("meeting-case").value;
    const date = document.getElementById("meeting-date").value;
    const time = document.getElementById("meeting-start").value;
    const duration = Number(document.getElementById("meeting-duration").value);
    const message = document.getElementById("meeting-form-message");
    const button = document.getElementById("btn-create-meeting");

    message.textContent = "";

    if (!caseId || !date || !time) {
      alert("Please select a case, meeting date, and start time.");
      return;
    }

    const start = new Date(`${date}T${time}:00`);

    if (Number.isNaN(start.getTime())) {
      alert("Please enter a valid meeting date and time.");
      return;
    }

    const end = new Date(start.getTime() + duration * 60000);

    button.disabled = true;

    try {
      await request("/mediator_scheduled_meetings", {
        method: "POST",
        body: JSON.stringify({
          meeting: {
            ConversationID: Number(caseId),
            StartTime: start.toISOString(),
            EndTime: end.toISOString()
          }
        })
      });

      message.style.color = "#15803d";
      message.textContent = "Meeting scheduled successfully.";

      document.getElementById("meeting-date").value = "";
      document.getElementById("meeting-start").value = "";

      await loadMeetings();
    } catch (error) {
      message.style.color = "#dc2626";
      message.textContent = error.message;
    } finally {
      button.disabled = false;
    }
  });

  loadAvailability();
  loadBlocks();
  loadMeetings();
}

document.addEventListener("turbo:load", initializeMediatorSchedule);