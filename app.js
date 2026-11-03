// Rocket League Mafia - Supabase lobby connection
// The publishable key is designed for browser use. Never put a service-role key here.
const SUPABASE_URL = "https://ugfdvadraznjbhgycuez.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_jWHZ2LnWAX6x74G5vaQbDA_BA56asBB";
const db = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);

const $ = (id) => document.getElementById(id);
const screens = [...document.querySelectorAll(".screen")];
let currentRoomCode = null;
let isLobbyCreator = false;
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
  if (data.room_status === "finished") { await showFinalStandings(); return; }
  $("endGameBtn").hidden = !isLobbyCreator;

  if (data.current_round) currentRoundId = data.current_round.id;

  // Load this player's private assignment once, then follow the shared round status.
  if (data.current_round?.status === "playing" && data.current_round.id !== assignmentLoadedFor) {
    try {
      const { data: assignment, error: assignmentError } = await db.rpc("get_my_assignment", {
        p_round_id: data.current_round.id
      });
      if (assignmentError) throw assignmentError;
      $("roundNumber").textContent = String(data.current_round.round_number).padStart(2, "0");
      $("rolePlayerName").textContent = assignment.player_name || "";
      $("roleTitle").textContent = assignment.role === "imposter" ? "IMPOSTER" : "TEAMMATE";
      $("roleSymbol").textContent = assignment.role === "imposter" ? "◆" : "◇";
      $("roleCard").classList.toggle("imposter", assignment.role === "imposter");
      $("roleCard").dataset.role = assignment.role;
      $("roleTaskTitle").textContent = assignment.task;
      $("reportPlayerName").textContent = assignment.player_name || "";
      $("reportRoleLabel").textContent = assignment.role === "imposter" ? "IMPOSTER" : "TEAMMATE";
      $("reportTaskTitle").textContent = assignment.task;
      $("reportSecretCard").classList.toggle("imposter", assignment.role === "imposter");
      $("resultsScreen").classList.toggle("imposter-report", assignment.role === "imposter");
      assignmentLoadedFor = data.current_round.id;
      show("roleScreen");
      toast("Round started. Your role is ready.");
    } catch (assignmentError) {
      console.error(assignmentError);
      toast("Your assignment couldn't load: " + assignmentError.message);
    }
  }

  if (data.current_round?.status === "playing" || data.current_round?.status === "voting" || data.current_round?.status === "completed") {
    await updateRoundProgress(players, data.current_round.status, data.my_player_id);
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
let selectedVoteTarget = null;
let progressBusy = false;
let finalizingRound = false;
let resultsShownFor = null;

async function updateRoundProgress(players, knownStatus, myPlayerId) {
  if (!currentRoundId || progressBusy) return;
  progressBusy = true;
  try {
    const { data: progress, error } = await db.rpc("get_round_progress", {
      p_round_id: currentRoundId
    });
    if (error) throw error;

    if (progress.status === "playing") {
      if (progress.my_report_submitted && $("resultsScreen").classList.contains("active")) {
        $("submitResultsBtn").textContent = "Results submitted";
        $("submitResultsBtn").disabled = true;
        $("resultsWaitMessage").textContent =
          "Your report is saved. Waiting for the other players (" +
          progress.reports_received + "/" + progress.reports_total + ").";
      }
      return;
    }

    if (progress.status === "voting") {
      if (!$("voteScreen").classList.contains("active") &&
          !$("voteResultsScreen").classList.contains("active") &&
          !$("scoreboardScreen").classList.contains("active")) {
        show("voteScreen");
      }
      const votesRemaining = Math.max(0, progress.votes_total - progress.votes_received);
      $("voteProgress").textContent = progress.my_vote_submitted
        ? "Your vote is in. " + votesRemaining + " players still need to vote."
        : progress.votes_received + " of " + progress.votes_total + " votes in. " + votesRemaining + " still needed.";
      $("submitVoteBtn").disabled = progress.my_vote_submitted || !selectedVoteTarget;
      $("submitVoteBtn").textContent = progress.my_vote_submitted ? "Vote submitted" : "Submit my vote";
      if (!progress.my_vote_submitted) renderVoteChoices(players, myPlayerId);
      if (progress.votes_total > 0 && progress.votes_received >= progress.votes_total) {
        await finishRoundAndShowResults();
      }
      return;
    }

    if (progress.status === "completed") {
      await showRoundResults();
    }
  } catch (error) {
    console.error("Round progress:", error);
  } finally {
    progressBusy = false;
  }
}

function renderVoteChoices(players, myPlayerId) {
  const list = $("voteList");
  if (!list || list.dataset.rendered === currentRoundId) return;
  list.innerHTML = players.filter(player => player.id !== myPlayerId).map(player =>
    '<button class="choice vote-choice" type="button" data-vote-target="' +
    escapeHtml(player.id) + '">' + escapeHtml(player.display_name) + '</button>'
  ).join("");
  list.dataset.rendered = currentRoundId;
  list.querySelectorAll("[data-vote-target]").forEach(button => {
    button.addEventListener("click", () => {
      selectedVoteTarget = button.dataset.voteTarget;
      list.querySelectorAll("[data-vote-target]").forEach(item =>
        item.classList.toggle("selected", item === button)
      );
      $("submitVoteBtn").disabled = false;
    });
  });
}

async function finishRoundAndShowResults() {
  if (finalizingRound || !currentRoundId) return;
  finalizingRound = true;
  try {
    const { error } = await db.rpc("finalize_round", { p_round_id: currentRoundId });
    if (error && !/already been finalized/i.test(error.message)) {
      // Another player's browser may have finalized it first. Confirm below.
      const { data: state } = await db.rpc("get_round_progress", { p_round_id: currentRoundId });
      if (state?.status !== "completed") throw error;
    }
    await showRoundResults();
  } catch (error) {
    console.error(error);
    toast(error.message || "Couldn't finalize the round");
  } finally {
    finalizingRound = false;
  }
}

async function showRoundResults() {
  if (!currentRoundId) return;
  if (resultsShownFor === currentRoundId) return;
  const roundId = currentRoundId;
  const { data, error } = await db.rpc("get_round_results", { p_round_id: roundId });
  if (error) {
    console.error(error);
    toast("Couldn't load round results: " + error.message);
    return;
  }
  if (currentRoundId !== roundId) return;

  const imposters = data.imposters || [];
  const names = imposters.map(player => player.display_name).join(", ");
  const isImposter = data.my_role === "imposter";
  const success = isImposter ? !data.correct_vote : data.correct_vote;
  const outcomeCard = $("roundOutcomeCard");
  outcomeCard.classList.remove("success", "failure", "neutral");
  outcomeCard.classList.add(success ? "success" : "failure");

  $("voteOutcomeTitle").textContent = isImposter
    ? (success ? "You fooled the group." : "You were caught.")
    : (success ? "The imposter was caught." : "The imposter got away.");
  $("roundOutcomeStatus").textContent = success ? "SUCCESS" : "ROUND FAILED";
  $("roundOutcomeRole").textContent = isImposter ? "IMPOSTER RESULT" : "TEAMMATE RESULT";

  if (isImposter) {
    if (data.correct_vote) {
      $("voteSummary").textContent = names + " was identified by the group. Your cover was blown.";
    } else if (data.tie) {
      $("voteSummary").textContent = "The vote was tied. Nobody was identified, so you survived the vote.";
    } else {
      $("voteSummary").textContent = "The group voted for " + (data.identified_player || "someone else") +
        " instead of you. You stayed hidden.";
      if (data.imposter_alignment_bonus > 0) {
        $("voteSummary").textContent += " You also earned +" + data.imposter_alignment_bonus +
          " for voting with the majority.";
      }
    }
  } else if (data.correct_vote) {
    $("voteSummary").textContent = "The group correctly identified " +
      (data.identified_player || "the imposter") + ". You earned +" +
      data.teammate_vote_bonus + " voting bonus points.";
  } else if (data.tie) {
    $("voteSummary").textContent = "The vote was tied, so the imposter escaped identification. No voting bonus this round.";
  } else {
    $("voteSummary").textContent = "The group voted for " +
      (data.identified_player || "the wrong player") + ". The imposter escaped, and no voting bonus was awarded.";
  }

  const myPoints = Number(data.my_round_points || 0);
  $("roundPoints").textContent = (myPoints > 0 ? "+" : "") + myPoints + " points this round";
  $("roundPoints").hidden = Number(data.round_number) === 1;
  $("scoreboardList").innerHTML = (data.leaderboard || []).map((player, index) => {
    const showMovement = Number(data.round_number) > 1;
    const movement = Number(player.rank_change || 0);
    const movementText = movement > 0 ? "↑ " + movement : movement < 0 ? "↓ " + Math.abs(movement) : "—";
    const movementClass = movement > 0 ? "rank-up" : movement < 0 ? "rank-down" : "rank-stay";
    const roundPoints = Number(player.round_points || 0);
    const pointsText = (roundPoints > 0 ? "+" : "") + roundPoints;
    return '<div class="scoreboard-row' + (player.is_you ? ' is-you' : '') + '">' +
      '<div class="rank-number">' + (index + 1) + '</div>' +
      '<div class="scoreboard-player"><strong>' + escapeHtml(player.display_name) +
      (player.is_you ? ' <span class="you-tag">YOU</span>' : '') + '</strong>' +
      (showMovement ? '<small class="' + movementClass + '">' + movementText + ' places</small>' : '') + '</div>' +
      '<div class="score-total"><strong>' + player.score + ' pts</strong>' +
      (showMovement ? '<small class="' + (roundPoints > 0 ? 'points-up' : roundPoints < 0 ? 'points-down' : 'points-zero') +
      '">' + pointsText + ' this round</small>' : '') + '</div></div>';
  }).join("");
  resultsShownFor = roundId;
  show("voteResultsScreen");
}

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
$("submitVoteBtn").onclick = async () => {
  if (!currentRoundId || !selectedVoteTarget || busy) return;
  $("submitVoteBtn").disabled = true;
  $("submitVoteBtn").textContent = "Vote submitted";
  try {
    const { error } = await db.rpc("submit_vote", {
      p_round_id: currentRoundId,
      p_target_player_id: selectedVoteTarget
    });
    if (error) throw error;
    $("submitVoteBtn").textContent = "Vote submitted";
    $("submitVoteBtn").disabled = true;
    await refreshLobby();
  } catch (error) {
    console.error(error);
    toast(error.message || "Couldn't submit your vote");
  } finally {
    $("submitVoteBtn").textContent = "Submit my vote";
    $("submitVoteBtn").disabled = false;
  }
};

$("newRoundBtn").onclick = () => {
  currentRoundId = null;
  assignmentLoadedFor = null;
  selectedVoteTarget = null;
  show("lobbyScreen");
  refreshLobby();
};
$("finishGameBtn").onclick = () => show("endScreen");
$("backHomeBtn").onclick = () => {
  stopLobbyRefresh();
  currentRoomCode = null;
  currentRoundId = null;
  show("homeScreen");
};

$("submitResultsBtn").onclick = async () => {
  if (!currentRoundId || selectedMatchResult === null || selectedTaskCompleted === null || busy) return;
  let reportSubmitted = false;
  setBusy(true, "submitResultsBtn");
  try {
    const { data, error } = await db.rpc("submit_round_report", {
      p_round_id: currentRoundId,
      p_match_result: selectedMatchResult,
      p_task_completed: selectedTaskCompleted
    });
    if (error) throw error;
    reportSubmitted = true;
    $("submitResultsBtn").textContent = "Results submitted";
    $("submitResultsBtn").disabled = true;
    if (data.voting_open) {
      toast("All reports are in. Voting is opening.");
    } else {
      toast("Your results are saved. Waiting for the other players (" +
        data.reports_received + "/" + data.players_total + ").");
    }
    await refreshLobby();
  } catch (error) {
    console.error(error);
    toast(error.message || "Couldn't submit your results");
  } finally {
    setBusy(false, "submitResultsBtn");
    if (reportSubmitted) {
      $("submitResultsBtn").textContent = "Results submitted";
      $("submitResultsBtn").disabled = true;
    }
  }
};

window.addEventListener("beforeunload", stopLobbyRefresh);
