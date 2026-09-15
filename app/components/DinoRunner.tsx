"use client";

import { useEffect, useRef, useState } from "react";

type Props = {
  sessionId: string;
  seed: number;
  running: boolean;
  speedLevel: number;
  difficultyLevel: number;
  onProgress: (score: number) => void;
  onCrash: (score: number) => void;
};

type Obstacle = { x: number; width: number; height: number };

const BASE_SPEED = 280;
const MAX_SPEED_BONUS = 240;
const SPEED_SCORE_DIVISOR = 12;
const JUMP_VELOCITY = -615;
const GRAVITY = 1900;

function scoreDifficultyStage(score: number) {
  return Math.min(6, Math.floor(score / 500) + 1);
}

export function DinoRunner({ sessionId, seed, running, speedLevel, difficultyLevel, onProgress, onCrash }: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const jumpRef = useRef<() => void>(() => undefined);
  const finishRef = useRef<() => void>(() => undefined);
  const progressRef = useRef(onProgress);
  const crashRef = useRef(onCrash);
  const [score, setScore] = useState(0);
  const [crashed, setCrashed] = useState(false);

  useEffect(() => { progressRef.current = onProgress; }, [onProgress]);
  useEffect(() => { crashRef.current = onCrash; }, [onCrash]);

  useEffect(() => {
    if (!canvasRef.current || !running) return;
    const canvasElement: HTMLCanvasElement = canvasRef.current;
    const maybeContext = canvasElement.getContext("2d");
    if (!maybeContext) return;
    const drawingContext: CanvasRenderingContext2D = maybeContext;

    let width = 720;
    let height = 280;
    let frame = 0;
    let stopped = false;
    let previousTime = performance.now();
    let playedSeconds = 0;
    let shownScore = -1;
    let lastMilestone = 0;
    let dinoY = 0;
    let velocityY = 0;
    let randomState = (seed || 1) >>> 0;
    let nextObstacleGap = 360;
    const safeSpeedLevel = Math.max(1, Math.min(5, speedLevel));
    const safeDifficultyLevel = Math.max(1, Math.min(5, difficultyLevel));
    const speedMultiplier = 1 + (safeSpeedLevel - 1) * 0.16;
    const difficultyBonus = (safeDifficultyLevel - 1) * 22;
    const obstacles: Obstacle[] = [];
    const stars = Array.from({ length: 34 }, (_, index) => ({
      x: ((index * 97 + seed * 13) % 997) / 997,
      y: ((index * 53 + seed * 7) % 211) / 211,
      size: index % 4 === 0 ? 2 : 1,
    }));

    function nextRandom() {
      randomState = (Math.imul(randomState, 1664525) + 1013904223) >>> 0;
      return randomState / 4294967296;
    }

    function resize() {
      const ratio = Math.min(window.devicePixelRatio || 1, 2);
      width = Math.max(320, canvasElement.clientWidth);
      height = Math.max(230, canvasElement.clientHeight);
      canvasElement.width = Math.round(width * ratio);
      canvasElement.height = Math.round(height * ratio);
      drawingContext.setTransform(ratio, 0, 0, ratio, 0, 0);
      if (dinoY === 0) dinoY = height - 98;
    }

    function jump() {
      const groundY = height - 98;
      if (!stopped && dinoY >= groundY - 2) velocityY = JUMP_VELOCITY;
    }

    function finish() {
      if (stopped) return;
      stopped = true;
      window.cancelAnimationFrame(frame);
      setCrashed(true);
      crashRef.current(Math.floor(playedSeconds * 50));
    }

    jumpRef.current = jump;
    finishRef.current = finish;
    setScore(0);
    setCrashed(false);
    resize();

    const resizeObserver = new ResizeObserver(resize);
    resizeObserver.observe(canvasElement);

    function onKeyDown(event: KeyboardEvent) {
      if (event.code === "Space" || event.code === "ArrowUp") {
        event.preventDefault();
        jump();
      }
    }
    window.addEventListener("keydown", onKeyDown);

    function draw(currentScore: number, speed: number) {
      const ground = height - 50;
      drawingContext.clearRect(0, 0, width, height);

      const sky = drawingContext.createLinearGradient(0, 0, 0, height);
      sky.addColorStop(0, "#07100b");
      sky.addColorStop(1, "#10251a");
      drawingContext.fillStyle = sky;
      drawingContext.fillRect(0, 0, width, height);

      drawingContext.fillStyle = "rgba(149,255,190,.38)";
      for (const star of stars) {
        const starX = (star.x * width - playedSeconds * (10 + star.size * 3)) % width;
        drawingContext.fillRect(starX < 0 ? starX + width : starX, 16 + star.y * (height - 110), star.size, star.size);
      }

      drawingContext.fillStyle = "rgba(47,100,68,.42)";
      for (let x = -80; x < width + 100; x += 95) {
        const hillX = x - (playedSeconds * 20) % 95;
        drawingContext.beginPath();
        drawingContext.moveTo(hillX, ground);
        drawingContext.lineTo(hillX + 48, ground - 48);
        drawingContext.lineTo(hillX + 96, ground);
        drawingContext.fill();
      }

      drawingContext.strokeStyle = "#72f59a";
      drawingContext.lineWidth = 3;
      drawingContext.beginPath();
      drawingContext.moveTo(0, ground);
      drawingContext.lineTo(width, ground);
      drawingContext.stroke();

      drawingContext.fillStyle = "rgba(114,245,154,.33)";
      const groundOffset = (playedSeconds * speed) % 38;
      for (let x = -38; x < width + 38; x += 38) drawingContext.fillRect(x - groundOffset, ground + 13, 20, 3);

      drawingContext.fillStyle = "#7cf6a0";
      drawingContext.fillRect(72, dinoY + 13, 38, 30);
      drawingContext.fillRect(96, dinoY, 27, 26);
      drawingContext.fillRect(63, dinoY + 23, 14, 11);
      drawingContext.fillStyle = "#08110c";
      drawingContext.fillRect(113, dinoY + 7, 4, 4);
      drawingContext.fillStyle = "#7cf6a0";
      const legPhase = Math.floor(playedSeconds * 12) % 2;
      drawingContext.fillRect(79 + legPhase * 13, dinoY + 40, 8, 16);
      drawingContext.fillRect(101 - legPhase * 13, dinoY + 40, 8, 16);

      drawingContext.fillStyle = "#ffb45f";
      for (const obstacle of obstacles) {
        const top = ground - obstacle.height;
        drawingContext.fillRect(obstacle.x, top, obstacle.width, obstacle.height);
        drawingContext.fillRect(obstacle.x - 7, top + 13, 8, 8);
        drawingContext.fillRect(obstacle.x + obstacle.width - 1, top + 23, 8, 8);
      }
    }

    function tick(now: number) {
      if (stopped) return;
      const delta = Math.min((now - previousTime) / 1000, 0.04);
      previousTime = now;
      playedSeconds += delta;
      const currentScore = Math.floor(playedSeconds * 50);
      const speed = BASE_SPEED * speedMultiplier + Math.min(currentScore / SPEED_SCORE_DIVISOR, MAX_SPEED_BONUS * speedMultiplier);
      const groundY = height - 98;

      velocityY += GRAVITY * delta;
      dinoY = Math.min(groundY, dinoY + velocityY * delta);
      if (dinoY >= groundY) velocityY = 0;

      for (const obstacle of obstacles) obstacle.x -= speed * delta;
      while (obstacles.length && obstacles[0].x + obstacles[0].width < -10) obstacles.shift();
      const last = obstacles[obstacles.length - 1];
      if (!last || width - last.x >= nextObstacleGap) {
        const clustered = nextRandom() > 0.68 - (safeDifficultyLevel - 1) * 0.08;
        const tall = !clustered && nextRandom() > 0.42 - (safeDifficultyLevel - 1) * 0.05;
        obstacles.push({
          x: width + 30,
          width: clustered ? 44 + difficultyBonus * 0.2 + Math.floor(nextRandom() * 18) : tall ? 27 : 22 + Math.floor(nextRandom() * 15),
          height: clustered ? 36 + difficultyBonus * 0.12 + Math.floor(nextRandom() * 12) : tall ? 62 + difficultyBonus * 0.16 + Math.floor(nextRandom() * 11) : 42 + difficultyBonus * 0.12 + Math.floor(nextRandom() * 15),
        });
        const shrinkingGap = Math.max(175, 305 - difficultyBonus - Math.floor(currentScore / 35));
        nextObstacleGap = shrinkingGap + Math.floor(nextRandom() * Math.max(75, 155 - (safeDifficultyLevel - 1) * 20));
      }

      const dinoLeft = 77;
      const dinoRight = 116;
      const dinoTop = dinoY + 5;
      const dinoBottom = dinoY + 53;
      const collided = obstacles.some((obstacle) => {
        const obstacleTop = height - 50 - obstacle.height;
        return dinoRight > obstacle.x + 3
          && dinoLeft < obstacle.x + obstacle.width - 3
          && dinoBottom > obstacleTop + 4
          && dinoTop < height - 50;
      });

      if (currentScore - shownScore >= 10) {
        shownScore = currentScore;
        setScore(currentScore);
      }
      const milestone = Math.floor(currentScore / 1000);
      if (milestone > lastMilestone) {
        lastMilestone = milestone;
        progressRef.current(milestone * 1000);
      }

      draw(currentScore, speed);
      if (collided) {
        finish();
        return;
      }
      frame = window.requestAnimationFrame(tick);
    }

    frame = window.requestAnimationFrame(tick);
    return () => {
      stopped = true;
      window.cancelAnimationFrame(frame);
      window.removeEventListener("keydown", onKeyDown);
      resizeObserver.disconnect();
      jumpRef.current = () => undefined;
      finishRef.current = () => undefined;
    };
  }, [difficultyLevel, running, seed, sessionId, speedLevel]);

  return (
    <div className={`dino-runner ${crashed ? "crashed" : ""}`}>
      <div className="dino-scoreboard" aria-live="polite">
        <span>PUNKTE</span><strong>{score.toLocaleString("de-CH")}</strong>
        <small>Tempo: Stufe {Math.max(1, Math.min(5, speedLevel))} von 5</small>
        <small>Schwierigkeit: {Math.max(1, Math.min(5, difficultyLevel))}/5 · Laufstufe {scoreDifficultyStage(score)}/6</small>
        <small>Nächste Prämie bei {((Math.floor(score / 1000) + 1) * 1000).toLocaleString("de-CH")}</small>
      </div>
      <canvas
        ref={canvasRef}
        className="dino-canvas"
        role="img"
        aria-label={`Dino Run mit ${score} Punkten`}
        tabIndex={0}
        onPointerDown={() => jumpRef.current()}
      />
      <div className="dino-actions">
        <button type="button" className="primary dino-jump" disabled={!running || crashed} onClick={() => jumpRef.current()}>↑ Springen</button>
        <button type="button" className="secondary compact" disabled={!running || crashed} onClick={() => finishRef.current()}>Lauf beenden</button>
        <small>Leertaste, Pfeil hoch oder Spielfeld antippen</small>
      </div>
    </div>
  );
}
