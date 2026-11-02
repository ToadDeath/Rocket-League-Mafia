// Rocket League Mafia - Supabase lobby connection
// The publishable key is designed for browser use. Never put a service-role key here.
const SUPABASE_URL = "https://ugfdvadraznjbhgycuez.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_jWHZ2LnWAX6x74G5vaQbDA_BA56asBB";
const db = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);

const $ = (id) => document.getElementById(id);
const screens = [...document.querySelectorAll(".screen")];
let currentRoomCode = null;
let refreshTimer = null;
let busy = false;
let currentRoundId = null;
let assignmentLoadedFor = null;

function show(id) {
  screens.forEach((screen) => screen.classList.toggle("active", screen.id === id));
  window.scrollTo({ top: 0, behavior: "smooth" });
}
function toast(message) {
  $("toast").textContent = message;
  $("toast").classList.add("show");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => $("toast").classList.remove("show"), 3200);
}
function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]));
}
function setBusy(value, buttonId) {
  busy = value;
  if (buttonId) {
    const button = $(buttonId);
    button.disabled = value;
    button.dataset.originalText ||= button.textContent;
    button.textContent = value ? "Connecting..." : button.dataset.originalText;
  }
}
async function ensureSignedIn() {
  const { data, error } = await db.auth.getSession();
  if (error) throw error;
  if (data.session) return data.session;
  const result = await db.auth.signInAnonymously();
  if (result.error) throw result.error;
  return result.data.session;
}
function readSettings() {
  return {
    imposter_count: Number($("imposterCount").value),
    teammate_task_points: Number($("teammateTaskPts").value),
    teammate_win_points: Number($("teammateWinPts").value),
    correct_vote_points: Number($("correctVotePts").value),
    imposter_loss_points: Number($("imposterLossPts").value),
    imposter_task_points: Number($("imposterTaskPts").value),
    imposter_majority_alignment_bonus: Number($("imposterVotePts").value)
  };
}
function startLobbyRefresh() {
  stopLobbyRefresh();
  refreshLobby();
  refreshTimer = setInterval(refreshLobby, 3000);
}
function stopLobbyRefresh() {
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = null;
}
async function refreshLobby() {
  if (!currentRoomCode) return;
  const { data, error } = await db.rpc("get_room_state", { p_room_code: currentRoomCode });
  if (error) {
    console.error(error);
    toast("Couldn't refresh the lobby: " + error.message);
    return;
  }
  $("roomCode").textContent = data.room_code;
  const players = data.players || [];

  // When a round starts, each browser fetches only its own private assignment.
  if (data.current_round?.status === "playing" && data.current_round.id !== assignmentLoadedFor) {
    currentRoundId = data.current_round.id;
    try {
      const { data: assignment, error: assignmentError } = await db.rpc("get_my_assignment", {
        p_round_id: currentRoundId
      });
      if (assignmentError) throw assignmentError;
      assignmentLoadedFor = currentRoundId;
      $("roundNumber").textContent = String(data.current_round.round_number).padStart(2, "0");
      $("roleTitle").textContent = assignment.role === "imposter" ? "IMPOSTER" : "TEAMMATE";
      $("roleDescription").textContent = assignment.role === "imposter"
        ? "Blend in. Complete your secret objective. Avoid suspicion."
        : "Play your game. Complete your mission. Keep your eyes open.";
      $("roleSymbol").textContent = assignment.role === "imposter" ? "◆" : "◇";
      $("roleCard").classList.toggle("imposter", assignment.role === "imposter");
      $("roleCard").dataset.role = assignment.role;
      $("roleTaskTitle").textContent = assignment.task;
      $("reportRoleLabel").textContent = assignment.role === "imposter" ? "IMPOSTER" : "TEAMMATE";
      $("reportTaskTitle").textContent = assignment.task;
      $("reportSecretCard").classList.toggle("imposter", assignment.role === "imposter");
      show("roleScreen");
      toast("Round started. Your role is ready.");
    } catch (assignmentError) {
      console.error(assignmentError);
      toast("Round started, but your assignment couldn't load: " + assignmentError.message);
    }
  }
  $("playerCount").textContent = players.length + (players.length === 1 ? " PLAYER" : " PLAYERS");
  $("playerList").innerHTML = players.map((player, index) =>
    '<div class="player"><div class="avatar">' +
    escapeHtml((player.display_name || "?").slice(0, 1).toUpperCase()) +
    '</div><div><div class="player-name">' + escapeHtml(player.display_name) +
    '</div><div class="player-status">' + (index === 0 ? "IN THE LOBBY" : "CONNECTED") +
    '</div></div></div>'
  ).join("");
}
async function createLobby() {
  const name = $("hostName").value.trim();
  if (!name) return toast("Enter your player name");
  setBusy(true, "makeLobbyBtn");
  try {
    await ensureSignedIn();
    const { data, error } = await db.rpc("create_room", {
      p_display_name: name,
      p_settings: readSettings()
    });
    if (error) throw error;
    currentRoomCode = data.room_code;
    $("roomCode").textContent = currentRoomCode;
    show("lobbyScreen");
    startLobbyRefresh();
    toast("Lobby created. Share the room code with your players.");
  } catch (error) {
    console.error(error);
    toast(error.message || "Couldn't create the lobby");
  } finally {
    setBusy(false, "makeLobbyBtn");
  }
}
async function joinLobby() {
  const name = $("joinName").value.trim();
  const code = $("roomCodeInput").value.trim().toUpperCase();
  if (!name || !code) return toast("Enter your player name and room code");
  setBusy(true, "demoJoinBtn");
  try {
    await ensureSignedIn();
    const { data, error } = await db.rpc("join_room", {
      p_room_code: code,
      p_display_name: name
    });
    if (error) throw error;
    currentRoomCode = data.room_code;
    $("roomCode").textContent = currentRoomCode;
    show("lobbyScreen");
    startLobbyRefresh();
    toast("You joined the lobby.");
  } catch (error) {
    console.error(error);
    toast(error.message || "Couldn't join the lobby");
  } finally {
    setBusy(false, "demoJoinBtn");
  }
}

document.querySelectorAll("[data-back]").forEach((button) => {
  button.addEventListener("click", () => show(button.dataset.back));
});
$("createBtn").onclick = () => show("createScreen");
$("joinBtn").onclick = () => show("joinScreen");
$("homeLink").onclick = (event) => { event.preventDefault(); stopLobbyRefresh(); currentRoomCode = null; show("homeScreen"); };
$("helpBtn").onclick = () => $("helpDialog").showModal();
$("closeHelp").onclick = $("closeHelp2").onclick = () => $("helpDialog").close();
$("makeLobbyBtn").onclick = createLobby;
$("demoJoinBtn").onclick = joinLobby;
$("copyCode").onclick = async () => {
  try {
    await navigator.clipboard.writeText($("roomCode").textContent);
    toast("Room code copied.");
  } catch {
    toast("Room code: " + $("roomCode").textContent);
  }
};
$("leaveLobbyBtn").onclick = async () => {
  if (!currentRoomCode) { show("homeScreen"); return; }
  const code = currentRoomCode;
  $("leaveLobbyBtn").disabled = true;
  try {
    const { error } = await db.rpc("leave_room", { p_room_code: code });
    if (error) throw error;
    stopLobbyRefresh();
    currentRoomCode = null;
    show("homeScreen");
    toast("You left the lobby.");
  } catch (error) {
    toast(error.message || "Couldn't leave the lobby");
  } finally {
    $("leaveLobbyBtn").disabled = false;
  }
};
$("startGameBtn").onclick = async () => {
  if (!currentRoomCode || busy) return;
  setBusy(true, "startGameBtn");
  try {
    const { data, error } = await db.rpc("start_round", { p_room_code: currentRoomCode });
    if (error) throw error;
    toast("Round " + data.round_number + " started for " + data.players_in_round + " active players.");
    // Poll immediately so the player who launched also receives their private assignment.
    await refreshLobby();
  } catch (error) {
    console.error(error);
    toast(error.message || "Couldn't start the round");
  } finally {
    setBusy(false, "startGameBtn");
  }
};

let selectedMatchResult = null;
let selectedTaskCompleted = null;

$("goResultsBtn").onclick = () => {
  if (!currentRoundId) return toast("I couldn't find the active round. Refresh the lobby and try again.");
  $("resultsRound").textContent = $("roundNumber").textContent;
  selectedMatchResult = null;
  selectedTaskCompleted = null;
  document.querySelectorAll("[data-result], [data-task]").forEach((button) => button.classList.remove("selected"));
  $("submitResultsBtn").disabled = true;
  show("resultsScreen");
};

document.querySelectorAll("[data-result]").forEach((button) => {
  button.onclick = () => {
    selectedMatchResult = button.dataset.result;
    document.querySelectorAll("[data-result]").forEach((choice) => choice.classList.toggle("selected", choice === button));
    $("submitResultsBtn").disabled = selectedMatchResult === null || selectedTaskCompleted === null;
  };
});
document.querySelectorAll("[data-task]").forEach((button) => {
  button.onclick = () => {
    selectedTaskCompleted = button.dataset.task === "yes";
    document.querySelectorAll("[data-task]").forEach((choice) => choice.classList.toggle("selected", choice === button));
    $("submitResultsBtn").disabled = selectedMatchResult === null || selectedTaskCompleted === null;
  };
});
$("submitResultsBtn").onclick = async () => {
  if (!currentRoundId || selectedMatchResult === null || selectedTaskCompleted === null || busy) return;
  setBusy(true, "submitResultsBtn");
  try {
    const { data, error } = await db.rpc("submit_round_report", {
      p_round_id: currentRoundId,
      p_match_result: selectedMatchResult,
      p_task_completed: selectedTaskCompleted
    });
    if (error) throw error;
    if (data.voting_open) {
      toast("All match reports are in. Voting is opening next.");
    } else {
      toast("Your results are saved. Waiting for the other players (" +
        data.reports_received + "/" + data.players_total + ").");
    }
    $("submitResultsBtn").textContent = "Results submitted";
    $("submitResultsBtn").disabled = true;
  } catch (error) {
    console.error(error);
    toast(error.message || "Couldn't submit your results");
  } finally {
    setBusy(false, "submitResultsBtn");
  }
};

window.addEventListener("beforeunload", stopLobbyRefresh);
