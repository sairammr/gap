import React, { useState, useEffect, useRef, useMemo } from 'react';
import {
  TrendingUp,
  TrendingDown,
  ShieldAlert,
  Clock,
  Lock,
  Zap,
  ArrowUpRight,
  ArrowDownRight,
  MoveVertical,
  Sparkles,
  CheckCircle2,
  Sliders,
  History,
  Layers,
  Info,
  Wallet,
  RefreshCw,
  ChevronRight,
  AlertTriangle,
  BarChart3,
  ShieldCheck,
  Flame,
  Crosshair
} from 'lucide-react';

// --- DATASET: TOKENIZED STOCKS WITH OVERNIGHT GAP TELEMETRY ---
const ASSETS = [
  {
    id: 'tNVDA',
    name: 'Tokenized NVIDIA Corp.',
    ticker: 'tNVDA',
    closePrice: 142.80,
    syntheticPrice: 147.65,
    impliedGapPct: 3.40,
    overnightIV: 68.5,
    oneSdPct: 3.8,
    twoSdPct: 7.6,
    catalyst: 'Q3 Earnings Call Post-Close + AI Server Guidance',
    spotBalance: 45.0,
    intradaySeries: [138.2, 139.1, 138.8, 140.4, 141.2, 140.9, 141.8, 142.3, 142.1, 142.80],
    syntheticSeries: [142.80, 144.10, 143.80, 145.90, 146.40, 147.10, 147.65],
    historicalGaps: [
      { date: 'Nov 04', close: 136.50, open: 141.20, gapPct: +3.44, event: 'Macro Rally' },
      { date: 'Oct 29', close: 139.80, open: 135.90, gapPct: -2.79, event: 'Export Curb Rumor' },
      { date: 'Oct 22', close: 131.40, open: 138.10, gapPct: +5.10, event: 'Hyperscaler CapEx' },
      { date: 'Oct 15', close: 134.00, open: 129.10, gapPct: -3.66, event: 'ASML Guidance Miss' },
    ],
    freqOver2Pct: '64%'
  },
  {
    id: 'tTSLA',
    name: 'Tokenized Tesla Inc.',
    ticker: 'tTSLA',
    closePrice: 258.10,
    syntheticPrice: 250.85,
    impliedGapPct: -2.81,
    overnightIV: 74.2,
    oneSdPct: 4.2,
    twoSdPct: 8.4,
    catalyst: 'FSD Regulatory Filing & EU Tariff Vote Overnight',
    spotBalance: 20.0,
    intradaySeries: [264.0, 263.2, 261.5, 262.1, 260.4, 259.8, 258.9, 259.2, 258.4, 258.10],
    syntheticSeries: [258.10, 256.40, 255.10, 253.80, 252.90, 251.40, 250.85],
    historicalGaps: [
      { date: 'Nov 03', close: 249.00, open: 257.40, gapPct: +3.37, event: 'Delivery Beat' },
      { date: 'Oct 24', close: 213.65, open: 244.50, gapPct: +14.44, event: 'Q3 Earnings Rip' },
      { date: 'Oct 11', close: 238.77, open: 220.10, gapPct: -7.82, event: 'Robotaxi Event' },
      { date: 'Oct 02', close: 258.02, open: 249.50, gapPct: -3.30, event: 'Margin Check' },
    ],
    freqOver2Pct: '78%'
  },
  {
    id: 'tMSTR',
    name: 'Tokenized MicroStrategy',
    ticker: 'tMSTR',
    closePrice: 384.00,
    syntheticPrice: 405.10,
    impliedGapPct: 5.49,
    overnightIV: 96.0,
    oneSdPct: 5.5,
    twoSdPct: 11.0,
    catalyst: '24/7 BTC Midnight Breakout Above $94.5k',
    spotBalance: 12.0,
    intradaySeries: [368.0, 371.5, 374.0, 372.8, 376.5, 379.0, 381.2, 380.5, 382.9, 384.00],
    syntheticSeries: [384.00, 388.50, 392.00, 397.40, 399.80, 403.20, 405.10],
    historicalGaps: [
      { date: 'Nov 05', close: 342.00, open: 374.80, gapPct: +9.59, event: 'BTC Overnight Surge' },
      { date: 'Oct 30', close: 361.20, open: 344.00, gapPct: -4.76, event: 'ATM Offering Filing' },
      { date: 'Oct 21', close: 315.40, open: 334.90, gapPct: +6.18, event: 'Weekend BTC Gap' },
      { date: 'Oct 14', close: 298.00, open: 312.60, gapPct: +4.90, event: 'Short Squeeze' },
    ],
    freqOver2Pct: '89%'
  },
  {
    id: 'tAAPL',
    name: 'Tokenized Apple Inc.',
    ticker: 'tAAPL',
    closePrice: 231.50,
    syntheticPrice: 233.60,
    impliedGapPct: 0.91,
    overnightIV: 34.8,
    oneSdPct: 1.9,
    twoSdPct: 3.8,
    catalyst: 'Foxconn Monthly Shipment Telemetry @ 02:00 EST',
    spotBalance: 60.0,
    intradaySeries: [229.8, 230.1, 230.4, 230.2, 230.8, 231.0, 231.2, 231.1, 231.4, 231.50],
    syntheticSeries: [231.50, 231.80, 232.10, 232.60, 232.90, 233.25, 233.60],
    historicalGaps: [
      { date: 'Nov 01', close: 225.90, open: 222.10, gapPct: -1.68, event: 'Services Guide' },
      { date: 'Oct 18', close: 232.15, open: 236.40, gapPct: +1.83, event: 'China iPhone Data' },
      { date: 'Oct 07', close: 226.80, open: 224.30, gapPct: -1.10, event: 'Analyst Downgrade' },
      { date: 'Sep 23', close: 228.20, open: 226.00, gapPct: -0.96, event: 'Lead Time Report' },
    ],
    freqOver2Pct: '31%'
  }
];

const STRIKE_TIERS = [
  {
    id: 'atm',
    label: 'At-The-Close',
    sub: '0.0% Gap Offset',
    offsetPct: 0.0,
    costRate: 0.0165, // 1.65% of notional
    leverageBase: 16.5,
    tag: 'HIGH PROBABILITY'
  },
  {
    id: 'mod',
    label: 'Moderate Gap',
    sub: '±2.0% Gap Offset',
    offsetPct: 2.0,
    costRate: 0.0085, // 0.85% of notional
    leverageBase: 28.4,
    tag: 'SWEET SPOT'
  },
  {
    id: 'tail',
    label: 'Tail-Risk OTM',
    sub: '±4.5% Gap Offset',
    offsetPct: 4.5,
    costRate: 0.0038, // 0.38% of notional
    leverageBase: 54.0,
    tag: 'CONVEX EXPLOSION'
  }
];

export default function App() {
  // --- STATE ---
  const [selectedAssetId, setSelectedAssetId] = useState('tNVDA');
  const [appMode, setAppMode] = useState('speculate'); // 'speculate' | 'hedge'
  const [strategy, setStrategy] = useState('CALL'); // 'CALL' | 'PUT' | 'STRADDLE'
  const [strikeTierId, setStrikeTierId] = useState('mod');
  const [collateralUsdc, setCollateralUsdc] = useState(500);
  const [spotSharesToHedge, setSpotSharesToHedge] = useState(45);

  // Target Projected 9:30 AM Open % Gap (Interactive handle on canvas)
  const [projectedGapPct, setProjectedGapPct] = useState(4.8);
  const [isDraggingCanvas, setIsDraggingCanvas] = useState(false);

  // Bottom drawer tab
  const [bottomTab, setBottomTab] = useState('positions'); // 'positions' | 'scanner'

  // Live countdown seconds until 09:30 EST Open
  const [secondsLeft, setSecondsLeft] = useState(6 * 3600 + 42 * 60 + 19);

  // Notification toast / mint animation
  const [mintSuccessToast, setMintSuccessToast] = useState(null);

  // Active Overnight Positions
  const [positions, setPositions] = useState([
    {
      id: 'GAP-9042',
      asset: 'tNVDA',
      type: 'GAP UP (CALL)',
      mode: 'SPECULATE',
      closeAnchor: 142.80,
      strikePrice: 145.66,
      breakeven: 146.87,
      collateral: 500,
      leverage: 28.4,
      notionalShares: 99.4,
      currentSynthetic: 147.65,
      openedAt: '21:14 EST'
    },
    {
      id: 'GAP-8891',
      asset: 'tTSLA',
      type: 'GAP DOWN (PUT)',
      mode: 'BAG HEDGE',
      closeAnchor: 258.10,
      strikePrice: 252.94,
      breakeven: 250.75,
      collateral: 240,
      leverage: 26.1,
      notionalShares: 24.2,
      currentSynthetic: 250.85,
      openedAt: '16:45 EST'
    }
  ]);

  const svgRef = useRef(null);

  // Current selected asset object
  const asset = useMemo(
    () => ASSETS.find((a) => a.id === selectedAssetId) || ASSETS[0],
    [selectedAssetId]
  );

  // Current strike tier object
  const strikeTier = useMemo(
    () => STRIKE_TIERS.find((t) => t.id === strikeTierId) || STRIKE_TIERS[1],
    [strikeTierId]
  );

  // Sync default projected gap and shares when switching assets or modes
  const handleSelectAsset = (newAsset) => {
    setSelectedAssetId(newAsset.id);
    setSpotSharesToHedge(newAsset.spotBalance);
    // Set default target open slightly beyond implied gap so user sees clear action
    const defaultTarget =
      newAsset.impliedGapPct >= 0
        ? Math.max(3.5, Number((newAsset.impliedGapPct * 1.35).toFixed(1)))
        : Math.min(-3.5, Number((newAsset.impliedGapPct * 1.35).toFixed(1)));
    setProjectedGapPct(defaultTarget);
    if (appMode === 'speculate') {
      setStrategy(newAsset.impliedGapPct >= 0 ? 'CALL' : 'PUT');
    }
  };

  // Switch between Speculate and Protect My Spot Bag
  const handleModeSwitch = (newMode) => {
    setAppMode(newMode);
    if (newMode === 'hedge') {
      setStrategy('PUT');
      setStrikeTierId('atm');
      setSpotSharesToHedge(asset.spotBalance);
      setProjectedGapPct(-5.5); // Show how hedge pays off on a nasty -5.5% morning dump
    } else {
      setStrategy(asset.impliedGapPct >= 0 ? 'CALL' : 'PUT');
      setStrikeTierId('mod');
      setProjectedGapPct(asset.impliedGapPct >= 0 ? 4.8 : -4.8);
    }
  };

  // Countdown timer tick
  useEffect(() => {
    const timer = setInterval(() => {
      setSecondsLeft((prev) => (prev > 0 ? prev - 1 : 3600 * 17));
    }, 1000);
    return () => clearInterval(timer);
  }, []);

  const formatCountdown = (totalSec) => {
    const hrs = Math.floor(totalSec / 3600);
    const mins = Math.floor((totalSec % 3600) / 60);
    const secs = totalSec % 60;
    return `${String(hrs).padStart(2, '0')}h : ${String(mins).padStart(2, '0')}m : ${String(
      secs
    ).padStart(2, '0')}s`;
  };

  // --- OPTIONS & PAYOFF MATH (NO GREEKS DISPLAYED, PURE PRICE-TO-GAP GEOMETRY) ---
  const tradeMetrics = useMemo(() => {
    const close = asset.closePrice;
    const projectedOpenPrice = close * (1 + projectedGapPct / 100);
    const ivFactor = asset.overnightIV / 65; // Scale option cost slightly by overnight IV
    const effectiveCostRate =
      strikeTier.costRate * ivFactor * (strategy === 'STRADDLE' ? 1.75 : 1.0);

    // In HEDGE mode, collateral is auto-computed from the number of shares the user wants to insure
    let activeCollateral = collateralUsdc;
    let insuredNotionalUsd = 0;
    let effectiveShares = 0;

    if (appMode === 'hedge') {
      insuredNotionalUsd = spotSharesToHedge * close;
      activeCollateral = Math.max(15, Math.round(insuredNotionalUsd * effectiveCostRate));
      effectiveShares = spotSharesToHedge;
    } else {
      effectiveShares = activeCollateral / (close * effectiveCostRate);
      insuredNotionalUsd = effectiveShares * close;
    }

    const impliedLeverage = Number(((insuredNotionalUsd / activeCollateral) || 1).toFixed(1));
    const premiumPerShare = activeCollateral / (effectiveShares || 1);

    // Strike & Breakeven calculation
    const offset = strikeTier.offsetPct / 100;
    const upperStrike = close * (1 + offset);
    const lowerStrike = close * (1 - offset);

    const upperBreakeven = upperStrike + premiumPerShare;
    const lowerBreakeven = lowerStrike - premiumPerShare;

    const upperBreakevenPct = ((upperBreakeven - close) / close) * 100;
    const lowerBreakevenPct = ((lowerBreakeven - close) / close) * 100;

    // Gross Payout at Projected 9:30 AM Open Price
    let grossPayout = 0;
    if (strategy === 'CALL') {
      grossPayout = Math.max(0, projectedOpenPrice - upperStrike) * effectiveShares;
    } else if (strategy === 'PUT') {
      grossPayout = Math.max(0, lowerStrike - projectedOpenPrice) * effectiveShares;
    } else if (strategy === 'STRADDLE') {
      const upGain = Math.max(0, projectedOpenPrice - upperStrike);
      const downGain = Math.max(0, lowerStrike - projectedOpenPrice);
      grossPayout = Math.max(upGain, downGain) * effectiveShares;
    }

    const netProfit = grossPayout - activeCollateral;
    const roiMultiple = activeCollateral > 0 ? grossPayout / activeCollateral : 0;

    // Spot portfolio unhedged loss vs hedged floor (when in Hedge mode)
    const spotUnhedgedPnL = (projectedOpenPrice - close) * spotSharesToHedge;
    const hedgedCombinedPnL = spotUnhedgedPnL + netProfit;

    return {
      close,
      projectedOpenPrice,
      activeCollateral,
      effectiveShares,
      insuredNotionalUsd,
      impliedLeverage,
      upperStrike,
      lowerStrike,
      upperBreakeven,
      lowerBreakeven,
      upperBreakevenPct,
      lowerBreakevenPct,
      grossPayout,
      netProfit,
      roiMultiple,
      spotUnhedgedPnL,
      hedgedCombinedPnL
    };
  }, [asset, projectedGapPct, strikeTier, strategy, collateralUsdc, appMode, spotSharesToHedge]);

  // --- INTERACTIVE SVG GAP VISUALIZER DRAG LOGIC ---
  const MAX_GAP_PCT_AXIS = 10; // ±10% vertical range on canvas

  const updateProjectedGapFromClientY = (clientY) => {
    if (!svgRef.current) return;
    const rect = svgRef.current.getBoundingClientRect();
    const padTop = 36;
    const padBottom = 36;
    const usableHeight = rect.height - padTop - padBottom;
    const relY = Math.max(0, Math.min(usableHeight, clientY - rect.top - padTop));
    const pct = MAX_GAP_PCT_AXIS - (relY / usableHeight) * (MAX_GAP_PCT_AXIS * 2);
    const clamped = Math.max(-9.5, Math.min(9.5, Number(pct.toFixed(1))));
    setProjectedGapPct(clamped);
  };

  useEffect(() => {
    const handleWindowMove = (e) => {
      if (!isDraggingCanvas) return;
      const clientY = e.touches ? e.touches[0].clientY : e.clientY;
      updateProjectedGapFromClientY(clientY);
    };
    const handleWindowUp = () => {
      if (isDraggingCanvas) setIsDraggingCanvas(false);
    };
    if (isDraggingCanvas) {
      window.addEventListener('mousemove', handleWindowMove);
      window.addEventListener('mouseup', handleWindowUp);
      window.addEventListener('touchmove', handleWindowMove);
      window.addEventListener('touchend', handleWindowUp);
    }
    return () => {
      window.removeEventListener('mousemove', handleWindowMove);
      window.removeEventListener('mouseup', handleWindowUp);
      window.removeEventListener('touchmove', handleWindowMove);
      window.removeEventListener('touchend', handleWindowUp);
    };
  }, [isDraggingCanvas]);

  // Mint Position Handler
  const handleMintPosition = () => {
    const newId = `GAP-${Math.floor(1000 + Math.random() * 9000)}`;
    const typeLabel =
      strategy === 'CALL'
        ? 'GAP UP (CALL)'
        : strategy === 'PUT'
        ? 'GAP DOWN (PUT)'
        : 'TAIL STRADDLE';

    const strikeVal =
      strategy === 'CALL'
        ? tradeMetrics.upperStrike
        : strategy === 'PUT'
        ? tradeMetrics.lowerStrike
        : tradeMetrics.close;

    const beVal =
      strategy === 'CALL'
        ? tradeMetrics.upperBreakeven
        : strategy === 'PUT'
        ? tradeMetrics.lowerBreakeven
        : tradeMetrics.upperBreakeven;

    const newTicket = {
      id: newId,
      asset: asset.ticker,
      type: typeLabel,
      mode: appMode === 'hedge' ? 'BAG HEDGE' : 'SPECULATE',
      closeAnchor: asset.closePrice,
      strikePrice: Number(strikeVal.toFixed(2)),
      breakeven: Number(beVal.toFixed(2)),
      collateral: tradeMetrics.activeCollateral,
      leverage: tradeMetrics.impliedLeverage,
      notionalShares: Number(tradeMetrics.effectiveShares.toFixed(1)),
      currentSynthetic: asset.syntheticPrice,
      openedAt: 'JUST NOW'
    };

    setPositions((prev) => [newTicket, ...prev]);
    setBottomTab('positions');
    setMintSuccessToast({
      id: newId,
      ticker: asset.ticker,
      type: typeLabel,
      collateral: tradeMetrics.activeCollateral,
      leverage: tradeMetrics.impliedLeverage
    });
    setTimeout(() => {
      setMintSuccessToast(null);
    }, 4500);
  };

  // --- SVG COORDINATE HELPERS ---
  const SVG_W = 860;
  const SVG_H = 410;
  const PAD_Y = 36;
  const FREEZE_X = 330; // 16:00 EST TradFi Close Freeze Wall
  const OPEN_X = 720; // 09:30 EST Next-Day Open Settlement Line

  const pctToY = (pct) => {
    const usableH = SVG_H - PAD_Y * 2;
    const clamped = Math.max(-MAX_GAP_PCT_AXIS, Math.min(MAX_GAP_PCT_AXIS, pct));
    return PAD_Y + ((MAX_GAP_PCT_AXIS - clamped) / (MAX_GAP_PCT_AXIS * 2)) * usableH;
  };

  const priceToY = (price) => {
    const pct = ((price - asset.closePrice) / asset.closePrice) * 100;
    return pctToY(pct);
  };

  const closeY = pctToY(0);
  const targetY = pctToY(projectedGapPct);
  const syntheticY = priceToY(asset.syntheticPrice);
  const upperBeY = pctToY(tradeMetrics.upperBreakevenPct);
  const lowerBeY = pctToY(tradeMetrics.lowerBreakevenPct);

  // Build intraday historical path (Left of Freeze Wall)
  const intradayPath = useMemo(() => {
    const pts = asset.intradaySeries.map((p, idx) => {
      const x = 40 + (idx / (asset.intradaySeries.length - 1)) * (FREEZE_X - 40);
      const y = priceToY(p);
      return `${idx === 0 ? 'M' : 'L'} ${x.toFixed(1)} ${y.toFixed(1)}`;
    });
    return pts.join(' ');
  }, [asset]);

  // Build 24/7 overnight synthetic drift path (Inside Overnight Zone)
  const syntheticDriftPath = useMemo(() => {
    const currentEndX = FREEZE_X + (OPEN_X - FREEZE_X) * 0.56;
    const pts = asset.syntheticSeries.map((p, idx) => {
      const x =
        FREEZE_X + (idx / (asset.syntheticSeries.length - 1)) * (currentEndX - FREEZE_X);
      const y = priceToY(p);
      return `${idx === 0 ? 'M' : 'L'} ${x.toFixed(1)} ${y.toFixed(1)}`;
    });
    return {
      d: pts.join(' '),
      lastX: currentEndX,
      lastY: priceToY(asset.syntheticSeries[asset.syntheticSeries.length - 1])
    };
  }, [asset]);

  // Probability Cone Coordinates (1SD and 2SD from 16:00 Close to 09:30 Open)
  const oneSdTopY = pctToY(asset.oneSdPct);
  const oneSdBotY = pctToY(-asset.oneSdPct);
  const twoSdTopY = pctToY(asset.twoSdPct);
  const twoSdBotY = pctToY(-asset.twoSdPct);

  const isInProfitAtTarget = tradeMetrics.netProfit > 0;

  return (
    <div
      className="min-h-screen bg-[#08090C] text-[#F0F4F8] flex flex-col selection:bg-[#00F59B]/20 selection:text-[#00F59B]"
      style={{
        fontFamily:
          "'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif"
      }}
    >
      {/* SUBTLE MATRIX DOT BACKGROUND OVERLAY */}
      <div
        className="fixed inset-0 pointer-events-none opacity-25 z-0"
        style={{
          backgroundImage:
            'radial-gradient(#2A303C 1px, transparent 1px), linear-gradient(to right, rgba(30,34,45,0.22) 1px, transparent 1px), linear-gradient(to bottom, rgba(30,34,45,0.22) 1px, transparent 1px)',
          backgroundSize: '24px 24px, 96px 96px, 96px 96px'
        }}
      />

      {/* TOP HEADER BAR: BRAND + SESSION PHASE + MODE SWITCHER */}
      <header className="relative z-10 border-b border-[#1E222D] bg-[#0B0D12]/90 backdrop-blur-md px-4 lg:px-6 py-2.5">
        <div className="max-w-[1600px] mx-auto flex flex-wrap items-center justify-between gap-3">
          {/* Brand Identity */}
          <div className="flex items-center gap-3">
            <div className="w-9 h-9 bg-[#00F59B]/10 border border-[#00F59B]/50 flex items-center justify-center relative">
              <Zap className="w-4 h-4 text-[#00F59B]" />
              <span className="absolute -top-1 -right-1 w-2 h-2 bg-[#00F59B] animate-ping rounded-full" />
              <span className="absolute -top-1 -right-1 w-2 h-2 bg-[#00F59B] rounded-full" />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <span className="font-mono font-bold tracking-wider text-sm text-white">
                  GAP <span className="text-[#00F59B]">//</span> PROTOCOL
                </span>
                <span className="text-[10px] font-mono uppercase px-1.5 py-0.5 bg-[#151922] border border-[#262B38] text-[#94A3B8]">
                  v2.4 RWA-OPTIONS
                </span>
              </div>
              <p className="text-[11px] text-[#7E8B9B] hidden sm:block">
                Overnight Close-to-Open Gap Derivatives & Spot Bag Insurance
              </p>
            </div>
          </div>

          {/* Live Session Phase Timeline */}
          <div className="flex items-center gap-1.5 bg-[#08090C] border border-[#1E222D] px-3 py-1.5 rounded-none">
            <div className="flex items-center gap-1.5 pr-2 border-r border-[#1E222D]">
              <Lock className="w-3.5 h-3.5 text-[#F5A623]" />
              <span className="text-[11px] font-mono text-[#F5A623] font-medium">
                16:00 EST TRADFI ORACLE FROZEN
              </span>
            </div>
            <ChevronRight className="w-3.5 h-3.5 text-[#475569] hidden md:block" />
            <div className="hidden md:flex items-center gap-1.5 pr-2 border-r border-[#1E222D]">
              <span className="w-2 h-2 rounded-full bg-[#00F59B] animate-pulse" />
              <span className="text-[11px] font-mono text-[#E2E8F0]">
                OVERNIGHT DRIFT ACTIVE
              </span>
            </div>
            <div className="flex items-center gap-2 pl-1">
              <Clock className="w-3.5 h-3.5 text-[#00F59B]" />
              <span className="text-[11px] font-mono text-[#94A3B8]">09:30 OPEN IN:</span>
              <span className="text-xs font-mono font-bold text-white bg-[#131722] px-2 py-0.5 border border-[#262B38]">
                {formatCountdown(secondsLeft)}
              </span>
            </div>
          </div>

          {/* Mode Toggle: Speculate vs Protect My Spot Bag */}
          <div className="flex items-center gap-2">
            <div className="bg-[#08090C] p-0.5 border border-[#1E222D] flex items-center">
              <button
                onClick={() => handleModeSwitch('speculate')}
                className={`px-3 py-1.5 text-xs font-mono font-semibold transition-all flex items-center gap-1.5 ${
                  appMode === 'speculate'
                    ? 'bg-[#00F59B] text-[#08090C] shadow-[0_0_15px_rgba(0,245,155,0.25)]'
                    : 'text-[#8B95A5] hover:text-white'
                }`}
              >
                <Zap className="w-3.5 h-3.5" />
                SPECULATE ON GAP
              </button>
              <button
                onClick={() => handleModeSwitch('hedge')}
                className={`px-3 py-1.5 text-xs font-mono font-semibold transition-all flex items-center gap-1.5 ${
                  appMode === 'hedge'
                    ? 'bg-[#F5A623] text-[#08090C] shadow-[0_0_15px_rgba(245,166,35,0.25)]'
                    : 'text-[#8B95A5] hover:text-white'
                }`}
              >
                <ShieldCheck className="w-3.5 h-3.5" />
                PROTECT MY SPOT BAG
              </button>
            </div>

            <div className="hidden xl:flex items-center gap-2 bg-[#10131A] border border-[#1E222D] px-3 py-1.5 text-xs font-mono">
              <Wallet className="w-3.5 h-3.5 text-[#00F59B]" />
              <span className="text-[#8B95A5]">USDC:</span>
              <span className="text-white font-semibold">$14,820.00</span>
            </div>
          </div>
        </div>
      </header>

      {/* ASSET SELECTOR STRIP */}
      <section className="relative z-10 border-b border-[#1E222D] bg-[#090B10] px-4 lg:px-6 py-2">
        <div className="max-w-[1600px] mx-auto flex items-center justify-between gap-4 overflow-x-auto no-scrollbar">
          <div className="flex items-center gap-2">
            {ASSETS.map((item) => {
              const isSelected = item.id === asset.id;
              const isPos = item.impliedGapPct >= 0;
              return (
                <button
                  key={item.id}
                  onClick={() => handleSelectAsset(item)}
                  className={`group px-3.5 py-2 border text-left transition-all flex items-center gap-3 shrink-0 ${
                    isSelected
                      ? 'bg-[#121620] border-[#00F59B] shadow-[inset_0_1px_0_0_rgba(0,245,155,0.3)]'
                      : 'bg-[#0C0E14] border-[#1E222D] hover:border-[#32394A]'
                  }`}
                >
                  <div>
                    <div className="flex items-center gap-1.5">
                      <span className="font-mono font-bold text-xs text-white">
                        {item.ticker}
                      </span>
                      <span
                        className={`text-[10px] font-mono px-1.5 py-0.2 font-semibold ${
                          isPos
                            ? 'bg-[#00F59B]/10 text-[#00F59B] border border-[#00F59B]/30'
                            : 'bg-[#FF3366]/10 text-[#FF3366] border border-[#FF3366]/30'
                        }`}
                      >
                        {isPos ? '+' : ''}
                        {item.impliedGapPct.toFixed(1)}% IMPLIED GAP
                      </span>
                    </div>
                    <div className="flex items-center gap-2 mt-0.5 text-[11px] font-mono">
                      <span className="text-[#7E8B9B]">
                        Close: <strong className="text-[#CBD5E1]">${item.closePrice.toFixed(2)}</strong>
                      </span>
                      <span className="text-[#475569]">→</span>
                      <span className="text-[#7E8B9B]">
                        Perp:{' '}
                        <strong className={isPos ? 'text-[#00F59B]' : 'text-[#FF3366]'}>
                          ${item.syntheticPrice.toFixed(2)}
                        </strong>
                      </span>
                    </div>
                  </div>
                </button>
              );
            })}
          </div>

          {/* Overnight Catalyst Alert Pill */}
          <div className="hidden lg:flex items-center gap-2 bg-[#14110B] border border-[#F5A623]/40 px-3 py-1.5 shrink-0">
            <Flame className="w-3.5 h-3.5 text-[#F5A623] shrink-0" />
            <span className="text-[11px] font-mono uppercase text-[#F5A623]">
              OVERNIGHT DRIVER:
            </span>
            <span className="text-xs text-[#F8FAFC] font-medium">{asset.catalyst}</span>
          </div>
        </div>
      </section>

      {/* MAIN WORKSPACE: LEFT INTERACTIVE GAP CANVAS (7 COLS) + RIGHT 3-STEP BUILDER (5 COLS) */}
      <main className="relative z-10 flex-1 max-w-[1600px] w-full mx-auto px-4 lg:px-6 py-4 grid grid-cols-1 lg:grid-cols-12 gap-5">
        {/* LEFT 7 COLUMNS: CLOSE-TO-OPEN GAP VISUALIZER */}
        <div className="lg:col-span-7 xl:col-span-8 flex flex-col bg-[#0B0D13] border border-[#1E222D]">
          {/* Visualizer Top Telemetry Header */}
          <div className="p-4 border-b border-[#1E222D] flex flex-wrap items-center justify-between gap-4 bg-[#0E1118]">
            <div className="flex flex-wrap items-center gap-5">
              <div>
                <div className="flex items-center gap-1.5 text-[11px] font-mono text-[#8B95A5]">
                  <Lock className="w-3 h-3 text-[#F5A623]" />
                  <span>16:00 EST LOCKED CLOSE</span>
                </div>
                <div className="text-lg font-mono font-bold text-white mt-0.5">
                  ${asset.closePrice.toFixed(2)}
                </div>
              </div>

              <div className="h-8 w-[1px] bg-[#1E222D]" />

              <div>
                <div className="flex items-center gap-1.5 text-[11px] font-mono text-[#8B95A5]">
                  <span className="w-2 h-2 rounded-full bg-[#38BDF8] animate-pulse" />
                  <span>24/7 ON-CHAIN SYNTHETIC</span>
                </div>
                <div className="flex items-baseline gap-2 mt-0.5">
                  <span className="text-lg font-mono font-bold text-[#38BDF8]">
                    ${asset.syntheticPrice.toFixed(2)}
                  </span>
                  <span
                    className={`text-xs font-mono font-semibold ${
                      asset.impliedGapPct >= 0 ? 'text-[#00F59B]' : 'text-[#FF3366]'
                    }`}
                  >
                    ({asset.impliedGapPct >= 0 ? '+' : ''}
                    {asset.impliedGapPct.toFixed(2)}%)
                  </span>
                </div>
              </div>

              <div className="h-8 w-[1px] bg-[#1E222D]" />

              <div>
                <div className="flex items-center gap-1.5 text-[11px] font-mono text-[#8B95A5]">
                  <Crosshair className="w-3 h-3 text-[#00F59B]" />
                  <span>YOUR SIMULATED 09:30 OPEN</span>
                </div>
                <div className="flex items-baseline gap-2 mt-0.5">
                  <span
                    className={`text-lg font-mono font-bold ${
                      projectedGapPct >= 0 ? 'text-[#00F59B]' : 'text-[#FF3366]'
                    }`}
                  >
                    ${tradeMetrics.projectedOpenPrice.toFixed(2)}
                  </span>
                  <span
                    className={`text-xs font-mono px-1.5 py-0.5 font-bold ${
                      projectedGapPct >= 0
                        ? 'bg-[#00F59B]/15 text-[#00F59B]'
                        : 'bg-[#FF3366]/15 text-[#FF3366]'
                    }`}
                  >
                    {projectedGapPct >= 0 ? '+' : ''}
                    {projectedGapPct.toFixed(1)}% GAP
                  </span>
                </div>
              </div>
            </div>

            {/* Quick Scenario Preset Buttons */}
            <div className="flex items-center gap-1.5 flex-wrap">
              <span className="text-[10px] font-mono uppercase text-[#64748B] mr-1">
                SIMULATE OPEN:
              </span>
              {[
                { label: 'Implied Perp', val: Number(asset.impliedGapPct.toFixed(1)) },
                { label: '+2.5% Mild', val: 2.5 },
                { label: '+6.0% Rip', val: 6.0 },
                { label: '-3.0% Dip', val: -3.0 },
                { label: '-6.5% Dump', val: -6.5 }
              ].map((preset) => (
                <button
                  key={preset.label}
                  onClick={() => setProjectedGapPct(preset.val)}
                  className={`px-2 py-1 text-[11px] font-mono border transition-all ${
                    Math.abs(projectedGapPct - preset.val) < 0.2
                      ? 'bg-[#1E2536] border-[#00F59B] text-white font-semibold'
                      : 'bg-[#0B0D13] border-[#1E222D] text-[#8B95A5] hover:text-white hover:border-[#333B4D]'
                  }`}
                >
                  {preset.label}
                </button>
              ))}
            </div>
          </div>

          {/* INTERACTIVE SVG CANVAS */}
          <div className="relative flex-1 min-h-[380px] select-none overflow-hidden bg-[#080A0E]">
            {/* Helper Floating Instruction Pill */}
            <div className="absolute top-3 left-3 z-20 pointer-events-none flex items-center gap-2 bg-[#0E121B]/90 border border-[#252B3B] px-2.5 py-1">
              <MoveVertical className="w-3.5 h-3.5 text-[#00F59B]" />
              <span className="text-[11px] font-mono text-[#CBD5E1]">
                Drag the <strong className="text-white">09:30 AM TARGET HANDLE</strong> up or down
                to stress-test your overnight gap payout
              </span>
            </div>

            <svg
              ref={svgRef}
              viewBox={`0 0 ${SVG_W} ${SVG_H}`}
              className={`w-full h-full block ${
                isDraggingCanvas ? 'cursor-ns-resize' : 'cursor-crosshair'
              }`}
              onMouseDown={(e) => {
                setIsDraggingCanvas(true);
                updateProjectedGapFromClientY(e.clientY);
              }}
              onTouchStart={(e) => {
                setIsDraggingCanvas(true);
                updateProjectedGapFromClientY(e.touches[0].clientY);
              }}
            >
              <defs>
                {/* Profit Zone Gradients */}
                <linearGradient id="callProfitGrad" x1="0" y1="1" x2="0" y2="0">
                  <stop offset="0%" stopColor="#00F59B" stopOpacity="0.04" />
                  <stop offset="100%" stopColor="#00F59B" stopOpacity="0.28" />
                </linearGradient>
                <linearGradient id="putProfitGrad" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor="#FF3366" stopOpacity="0.04" />
                  <stop offset="100%" stopColor="#FF3366" stopOpacity="0.28" />
                </linearGradient>
                <linearGradient id="overnightBgGrad" x1="0" y1="0" x2="1" y2="0">
                  <stop offset="0%" stopColor="#F5A623" stopOpacity="0.05" />
                  <stop offset="50%" stopColor="#0F1420" stopOpacity="0.4" />
                  <stop offset="100%" stopColor="#00F59B" stopOpacity="0.04" />
                </linearGradient>
              </defs>

              {/* LEFT ZONE: TRADFI REGULAR HOURS BACKGROUND */}
              <rect
                x="0"
                y={PAD_Y}
                width={FREEZE_X}
                height={SVG_H - PAD_Y * 2}
                fill="#090B10"
              />

              {/* RIGHT ZONE: OVERNIGHT GAP WINDOW BACKGROUND */}
              <rect
                x={FREEZE_X}
                y={PAD_Y}
                width={OPEN_X - FREEZE_X}
                height={SVG_H - PAD_Y * 2}
                fill="url(#overnightBgGrad)"
              />

              {/* HORIZONTAL PERCENTAGE GRID LINES (-8% to +8%) */}
              {[-8, -6, -4, -2, 0, 2, 4, 6, 8].map((pct) => {
                const y = pctToY(pct);
                const priceAtLine = asset.closePrice * (1 + pct / 100);
                return (
                  <g key={pct}>
                    <line
                      x1="0"
                      y1={y}
                      x2={SVG_W}
                      y2={y}
                      stroke={pct === 0 ? '#2E3646' : '#151924'}
                      strokeWidth={pct === 0 ? '1.5' : '1'}
                      strokeDasharray={pct === 0 ? '4 4' : undefined}
                    />
                    <text
                      x={SVG_W - 8}
                      y={y - 4}
                      textAnchor="end"
                      className="fill-[#526075] font-mono text-[10px]"
                    >
                      {pct > 0 ? `+${pct}%` : `${pct}%`} (${priceAtLine.toFixed(1)})
                    </text>
                  </g>
                );
              })}

              {/* SHADED PROFIT ZONES INSIDE OVERNIGHT WINDOW */}
              {(strategy === 'CALL' || strategy === 'STRADDLE') && (
                <g>
                  <rect
                    x={FREEZE_X}
                    y={PAD_Y}
                    width={OPEN_X - FREEZE_X}
                    height={Math.max(0, upperBeY - PAD_Y)}
                    fill="url(#callProfitGrad)"
                  />
                  <line
                    x1={FREEZE_X}
                    y1={upperBeY}
                    x2={OPEN_X + 60}
                    y2={upperBeY}
                    stroke="#00F59B"
                    strokeWidth="1.2"
                    strokeDasharray="5 4"
                  />
                  <rect
                    x={FREEZE_X + 10}
                    y={upperBeY - 18}
                    width="195"
                    height="16"
                    fill="#071914"
                    stroke="#00F59B"
                    strokeWidth="0.8"
                  />
                  <text
                    x={FREEZE_X + 16}
                    y={upperBeY - 7}
                    className="fill-[#00F59B] font-mono text-[10px] font-bold"
                  >
                    ▲ CALL BREAKEVEN: ${tradeMetrics.upperBreakeven.toFixed(2)} (
                    +{tradeMetrics.upperBreakevenPct.toFixed(1)}%)
                  </text>
                </g>
              )}

              {(strategy === 'PUT' || strategy === 'STRADDLE') && (
                <g>
                  <rect
                    x={FREEZE_X}
                    y={lowerBeY}
                    width={OPEN_X - FREEZE_X}
                    height={Math.max(0, SVG_H - PAD_Y - lowerBeY)}
                    fill="url(#putProfitGrad)"
                  />
                  <line
                    x1={FREEZE_X}
                    y1={lowerBeY}
                    x2={OPEN_X + 60}
                    y2={lowerBeY}
                    stroke="#FF3366"
                    strokeWidth="1.2"
                    strokeDasharray="5 4"
                  />
                  <rect
                    x={FREEZE_X + 10}
                    y={lowerBeY + 3}
                    width="195"
                    height="16"
                    fill="#1F0910"
                    stroke="#FF3366"
                    strokeWidth="0.8"
                  />
                  <text
                    x={FREEZE_X + 16}
                    y={lowerBeY + 14}
                    className="fill-[#FF3366] font-mono text-[10px] font-bold"
                  >
                    ▼ PUT BREAKEVEN: ${tradeMetrics.lowerBreakeven.toFixed(2)} (
                    {tradeMetrics.lowerBreakevenPct.toFixed(1)}%)
                  </text>
                </g>
              )}

              {/* OVERNIGHT IMPLIED VOLATILITY CONE (2SD AND 1SD) */}
              <polygon
                points={`${FREEZE_X},${closeY} ${OPEN_X},${twoSdTopY} ${OPEN_X},${twoSdBotY}`}
                fill="#64748B"
                fillOpacity="0.07"
                stroke="#475569"
                strokeWidth="0.6"
                strokeDasharray="2 4"
              />
              <polygon
                points={`${FREEZE_X},${closeY} ${OPEN_X},${oneSdTopY} ${OPEN_X},${oneSdBotY}`}
                fill="#38BDF8"
                fillOpacity="0.07"
                stroke="#38BDF8"
                strokeOpacity="0.25"
                strokeWidth="0.8"
                strokeDasharray="3 3"
              />
              <text
                x={OPEN_X - 6}
                y={oneSdTopY + 12}
                textAnchor="end"
                className="fill-[#38BDF8]/60 font-mono text-[9px]"
              >
                +1σ IV Cone (+{asset.oneSdPct}%)
              </text>
              <text
                x={OPEN_X - 6}
                y={oneSdBotY - 5}
                textAnchor="end"
                className="fill-[#38BDF8]/60 font-mono text-[9px]"
              >
                -1σ IV Cone (-{asset.oneSdPct}%)
              </text>

              {/* HISTORICAL INTRADAY CLOSE PATH (LEFT OF 16:00 WALL) */}
              <path
                d={intradayPath}
                fill="none"
                stroke="#94A3B8"
                strokeWidth="2"
              />
              <text
                x="24"
                y={PAD_Y + 16}
                className="fill-[#64748B] font-mono text-[10px] uppercase tracking-wider"
              >
                TRADFI REGULAR SESSION (09:30 – 16:00 EST)
              </text>

              {/* 16:00 EST ORACLE FREEZE VERTICAL WALL */}
              <line
                x1={FREEZE_X}
                y1={PAD_Y - 10}
                x2={FREEZE_X}
                y2={SVG_H - PAD_Y + 10}
                stroke="#F5A623"
                strokeWidth="2"
              />
              <rect
                x={FREEZE_X - 88}
                y={PAD_Y - 22}
                width="176"
                height="18"
                fill="#1C1408"
                stroke="#F5A623"
                strokeWidth="1"
              />
              <text
                x={FREEZE_X}
                y={PAD_Y - 10}
                textAnchor="middle"
                className="fill-[#F5A623] font-mono text-[10px] font-bold"
              >
                🔒 16:00 EST CLOSE FREEZE
              </text>

              {/* 24/7 SYNTHETIC PERP DRIFT PATH (INSIDE OVERNIGHT WINDOW) */}
              <path
                d={syntheticDriftPath.d}
                fill="none"
                stroke="#38BDF8"
                strokeWidth="2.2"
              />
              <circle
                cx={syntheticDriftPath.lastX}
                cy={syntheticDriftPath.lastY}
                r="4.5"
                fill="#38BDF8"
              />
              <circle
                cx={syntheticDriftPath.lastX}
                cy={syntheticDriftPath.lastY}
                r="9"
                fill="#38BDF8"
                fillOpacity="0.25"
              />
              <rect
                x={syntheticDriftPath.lastX - 65}
                y={syntheticDriftPath.lastY - 28}
                width="130"
                height="18"
                fill="#0B192C"
                stroke="#38BDF8"
                strokeWidth="1"
              />
              <text
                x={syntheticDriftPath.lastX}
                y={syntheticDriftPath.lastY - 16}
                textAnchor="middle"
                className="fill-[#38BDF8] font-mono text-[10px] font-semibold"
              >
                24/7 Perp: ${asset.syntheticPrice.toFixed(2)}
              </text>

              {/* PROJECTED GAP BEZIER PROJECTION CURVE FROM CLOSE ANCHOR TO 09:30 OPEN TARGET */}
              <path
                d={`M ${FREEZE_X} ${closeY} C ${FREEZE_X + 140} ${closeY}, ${
                  OPEN_X - 140
                } ${targetY}, ${OPEN_X} ${targetY}`}
                fill="none"
                stroke={
                  isInProfitAtTarget
                    ? strategy === 'PUT' && projectedGapPct < 0
                      ? '#FF3366'
                      : '#00F59B'
                    : '#94A3B8'
                }
                strokeWidth="3"
                strokeDasharray="6 4"
              />

              {/* LOCKED 16:00 CLOSE ANCHOR NODE */}
              <circle
                cx={FREEZE_X}
                cy={closeY}
                r="6"
                fill="#F5A623"
                stroke="#08090C"
                strokeWidth="2"
              />

              {/* 09:30 EST REOPEN SETTLEMENT VERTICAL LINE */}
              <line
                x1={OPEN_X}
                y1={PAD_Y - 10}
                x2={OPEN_X}
                y2={SVG_H - PAD_Y + 10}
                stroke="#E2E8F0"
                strokeWidth="1.5"
                strokeDasharray="3 3"
              />
              <rect
                x={OPEN_X - 82}
                y={PAD_Y - 22}
                width="164"
                height="18"
                fill="#111622"
                stroke="#475569"
                strokeWidth="1"
              />
              <text
                x={OPEN_X}
                y={PAD_Y - 10}
                textAnchor="middle"
                className="fill-[#F8FAFC] font-mono text-[10px] font-bold"
              >
                ⚡ 09:30 EST OPEN SETTLEMENT
              </text>

              {/* VERTICAL GAP BAR BETWEEN CLOSE LEVEL AND TARGET OPEN LEVEL */}
              <line
                x1={OPEN_X}
                y1={closeY}
                x2={OPEN_X}
                y2={targetY}
                stroke={projectedGapPct >= 0 ? '#00F59B' : '#FF3366'}
                strokeWidth="5"
                strokeOpacity="0.65"
              />

              {/* DRAGGABLE TARGET 9:30 AM OPEN HANDLE ON THE SETTLEMENT LINE */}
              <g
                transform={`translate(${OPEN_X}, ${targetY})`}
                className="cursor-ns-resize"
              >
                <circle
                  r="14"
                  fill={projectedGapPct >= 0 ? '#00F59B' : '#FF3366'}
                  fillOpacity="0.2"
                />
                <circle
                  r="7.5"
                  fill={projectedGapPct >= 0 ? '#00F59B' : '#FF3366'}
                  stroke="#08090C"
                  strokeWidth="2.5"
                />

                {/* Handle Callout Tag to the Left of Open Line */}
                <rect
                  x="-178"
                  y="-22"
                  width="164"
                  height="44"
                  fill="#0B0E17"
                  stroke={projectedGapPct >= 0 ? '#00F59B' : '#FF3366'}
                  strokeWidth="1.5"
                />
                <text
                  x="-96"
                  y="-6"
                  textAnchor="middle"
                  className="fill-white font-mono text-[11px] font-bold"
                >
                  OPEN: ${tradeMetrics.projectedOpenPrice.toFixed(2)} (
                  {projectedGapPct >= 0 ? '+' : ''}
                  {projectedGapPct.toFixed(1)}%)
                </text>
                <text
                  x="-96"
                  y="12"
                  textAnchor="middle"
                  className={`font-mono text-[11px] font-bold ${
                    tradeMetrics.netProfit >= 0
                      ? 'fill-[#00F59B]'
                      : 'fill-[#94A3B8]'
                  }`}
                >
                  {appMode === 'hedge'
                    ? `Hedge Payout: +$${tradeMetrics.grossPayout.toFixed(0)}`
                    : tradeMetrics.netProfit >= 0
                    ? `Est. Profit: +$${tradeMetrics.netProfit.toFixed(0)} (${tradeMetrics.roiMultiple.toFixed(
                        1
                      )}x)`
                    : `Max Loss Cap: -$${tradeMetrics.activeCollateral}`}
                </text>
              </g>
            </svg>
          </div>

          {/* Bottom Interactive Slider & Telemetry Strip under Canvas */}
          <div className="p-4 border-t border-[#1E222D] bg-[#0E1118] flex flex-col sm:flex-row items-stretch sm:items-center justify-between gap-4">
            <div className="flex-1 flex flex-col gap-1.5">
              <div className="flex items-center justify-between text-xs font-mono">
                <span className="text-[#8B95A5] flex items-center gap-1.5">
                  <Sliders className="w-3.5 h-3.5 text-[#00F59B]" />
                  <span>FINE-TUNE 09:30 AM OPEN GAP SCENARIO:</span>
                </span>
                <span
                  className={`font-bold ${
                    projectedGapPct >= 0 ? 'text-[#00F59B]' : 'text-[#FF3366]'
                  }`}
                >
                  {projectedGapPct >= 0 ? '+' : ''}
                  {projectedGapPct.toFixed(1)}% (${tradeMetrics.projectedOpenPrice.toFixed(2)})
                </span>
              </div>
              <input
                type="range"
                min="-9.5"
                max="9.5"
                step="0.1"
                value={projectedGapPct}
                onChange={(e) => setProjectedGapPct( parseFloat(e.target.value) )}
                className="w-full accent-[#00F59B] h-1.5 bg-[#1E222D] cursor-pointer"
              />
              <div className="flex justify-between text-[10px] font-mono text-[#64748B]">
                <span>-9.5% Crash Open</span>
                <span>0.0% Flat Open (${asset.closePrice.toFixed(2)})</span>
                <span>+9.5% Blowout Open</span>
              </div>
            </div>

            {/* Live Instant Scenario Readout Box */}
            <div className="bg-[#08090C] border border-[#1E222D] px-4 py-2.5 flex items-center gap-5 shrink-0">
              <div>
                <div className="text-[10px] font-mono text-[#64748B] uppercase">
                  AT ${tradeMetrics.projectedOpenPrice.toFixed(2)} OPEN
                </div>
                <div
                  className={`text-base font-mono font-bold ${
                    tradeMetrics.netProfit > 0 ? 'text-[#00F59B]' : 'text-[#94A3B8]'
                  }`}
                >
                  {tradeMetrics.netProfit > 0
                    ? `+$${tradeMetrics.netProfit.toFixed(2)} NET`
                    : `-$${tradeMetrics.activeCollateral.toFixed(2)} CAP`}
                </div>
              </div>
              <div className="h-7 w-[1px] bg-[#1E222D]" />
              <div>
                <div className="text-[10px] font-mono text-[#64748B] uppercase">
                  PAYOUT MULTIPLE
                </div>
                <div className="text-base font-mono font-bold text-white">
                  {tradeMetrics.roiMultiple.toFixed(2)}x
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* RIGHT 5 COLUMNS: FRICTIONLESS 3-STEP GAP POSITION BUILDER */}
        <div className="lg:col-span-5 xl:col-span-4 flex flex-col bg-[#0B0D13] border border-[#1E222D] justify-between">
          <div className="p-4 lg:p-5 space-y-5">
            {/* Builder Header */}
            <div className="flex items-center justify-between border-b border-[#1E222D] pb-3">
              <div>
                <span className="text-[10px] font-mono uppercase tracking-wider px-1.5 py-0.5 bg-[#00F59B]/10 text-[#00F59B] border border-[#00F59B]/30">
                  {appMode === 'hedge'
                    ? 'MODE // 1-CLICK BAG INSURANCE'
                    : 'MODE // DIRECTIONAL OR VOLATILITY GAP'}
                </span>
                <h2 className="text-base font-mono font-bold text-white mt-1.5">
                  {appMode === 'hedge'
                    ? `Insure ${asset.ticker} Overnight Bag`
                    : `Build ${asset.ticker} Overnight Gap Ticket`}
                </h2>
              </div>
              <div className="text-right font-mono">
                <div className="text-[10px] text-[#64748B]">OVERNIGHT IV</div>
                <div className="text-xs font-bold text-[#F5A623]">
                  {asset.overnightIV.toFixed(1)}%
                </div>
              </div>
            </div>

            {/* STEP 1: GAP DIRECTION / STRATEGY */}
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <label className="text-xs font-mono uppercase text-[#94A3B8] font-semibold">
                  STEP 1 // SELECT GAP STRATEGY
                </label>
                <span className="text-[11px] font-mono text-[#64748B]">
                  Settles 09:30 EST
                </span>
              </div>

              {appMode === 'hedge' ? (
                <div className="p-3 bg-[#14110B] border border-[#F5A623] flex items-center justify-between">
                  <div className="flex items-center gap-2.5">
                    <ShieldAlert className="w-5 h-5 text-[#F5A623] shrink-0" />
                    <div>
                      <div className="text-xs font-mono font-bold text-white">
                        PROTECTIVE OVERNIGHT PUT (100% DELTA FLOOR)
                      </div>
                      <div className="text-[11px] text-[#94A3B8]">
                        Locks in a hard price floor on your {asset.ticker} tokens until 09:30 AM
                        open.
                      </div>
                    </div>
                  </div>
                </div>
              ) : (
                <div className="grid grid-cols-3 gap-2">
                  <button
                    onClick={() => {
                      setStrategy('CALL');
                      if (projectedGapPct < 0) setProjectedGapPct(4.5);
                    }}
                    className={`p-2.5 border text-left transition-all ${
                      strategy === 'CALL'
                        ? 'bg-[#071914] border-[#00F59B] text-white shadow-[inset_0_1px_0_0_rgba(0,245,155,0.4)]'
                        : 'bg-[#0E1118] border-[#1E222D] text-[#8B95A5] hover:border-[#32394A]'
                    }`}
                  >
                    <div className="flex items-center justify-between">
                      <span className="text-xs font-mono font-bold text-[#00F59B]">
                        GAP UP
                      </span>
                      <ArrowUpRight className="w-4 h-4 text-[#00F59B]" />
                    </div>
                    <div className="text-[10px] font-mono text-[#CBD5E1] mt-1">
                      Long Call
                    </div>
                    <div className="text-[10px] text-[#64748B] mt-0.5">
                      Open &gt; Breakeven
                    </div>
                  </button>

                  <button
                    onClick={() => {
                      setStrategy('PUT');
                      if (projectedGapPct > 0) setProjectedGapPct(-4.5);
                    }}
                    className={`p-2.5 border text-left transition-all ${
                      strategy === 'PUT'
                        ? 'bg-[#1F0910] border-[#FF3366] text-white shadow-[inset_0_1px_0_0_rgba(255,51,102,0.4)]'
                        : 'bg-[#0E1118] border-[#1E222D] text-[#8B95A5] hover:border-[#32394A]'
                    }`}
                  >
                    <div className="flex items-center justify-between">
                      <span className="text-xs font-mono font-bold text-[#FF3366]">
                        GAP DOWN
                      </span>
                      <ArrowDownRight className="w-4 h-4 text-[#FF3366]" />
                    </div>
                    <div className="text-[10px] font-mono text-[#CBD5E1] mt-1">
                      Long Put
                    </div>
                    <div className="text-[10px] text-[#64748B] mt-0.5">
                      Open &lt; Breakeven
                    </div>
                  </button>

                  <button
                    onClick={() => {
                      setStrategy('STRADDLE');
                      if (Math.abs(projectedGapPct) < 3) setProjectedGapPct(6.0);
                    }}
                    className={`p-2.5 border text-left transition-all ${
                      strategy === 'STRADDLE'
                        ? 'bg-[#131629] border-[#38BDF8] text-white shadow-[inset_0_1px_0_0_rgba(56,189,248,0.4)]'
                        : 'bg-[#0E1118] border-[#1E222D] text-[#8B95A5] hover:border-[#32394A]'
                    }`}
                  >
                    <div className="flex items-center justify-between">
                      <span className="text-xs font-mono font-bold text-[#38BDF8]">
                        STRADDLE
                      </span>
                      <Sparkles className="w-4 h-4 text-[#38BDF8]" />
                    </div>
                    <div className="text-[10px] font-mono text-[#CBD5E1] mt-1">
                      Tail Explosion
                    </div>
                    <div className="text-[10px] text-[#64748B] mt-0.5">
                      Either Way ±Gap
                    </div>
                  </button>
                </div>
              )}
            </div>

            {/* STEP 2: GAP THRESHOLD (HUMAN-READABLE STRIKE DISTANCE) */}
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <label className="text-xs font-mono uppercase text-[#94A3B8] font-semibold">
                  STEP 2 // {appMode === 'hedge' ? 'DEDUCTIBLE BUFFER' : 'GAP THRESHOLD (STRIKE)'}
                </label>
                <span className="text-[11px] font-mono text-[#64748B]">
                  Zero Option-Chain Clutter
                </span>
              </div>

              <div className="grid grid-cols-3 gap-2">
                {STRIKE_TIERS.map((tier) => {
                  const isActive = strikeTierId === tier.id;
                  const strikePreview =
                    strategy === 'CALL'
                      ? (asset.closePrice * (1 + tier.offsetPct / 100)).toFixed(2)
                      : strategy === 'PUT'
                      ? (asset.closePrice * (1 - tier.offsetPct / 100)).toFixed(2)
                      : `±${tier.offsetPct}%`;

                  return (
                    <button
                      key={tier.id}
                      onClick={() => setStrikeTierId(tier.id)}
                      className={`p-2.5 border text-left transition-all flex flex-col justify-between ${
                        isActive
                          ? 'bg-[#141926] border-[#00F59B] text-white'
                          : 'bg-[#0E1118] border-[#1E222D] text-[#8B95A5] hover:border-[#2E3646]'
                      }`}
                    >
                      <div>
                        <div className="text-[10px] font-mono text-[#00F59B] font-semibold">
                          {tier.tag}
                        </div>
                        <div className="text-xs font-mono font-bold text-white mt-0.5">
                          {tier.label}
                        </div>
                        <div className="text-[10px] font-mono text-[#64748B]">
                          {tier.sub}
                        </div>
                      </div>
                      <div className="mt-2 pt-1.5 border-t border-[#1E222D] flex items-center justify-between text-[11px] font-mono">
                        <span className="text-[#94A3B8]">Strike:</span>
                        <span className="text-white font-semibold">
                          {strategy === 'STRADDLE' ? strikePreview : `$${strikePreview}`}
                        </span>
                      </div>
                    </button>
                  );
                })}
              </div>
            </div>

            {/* STEP 3: COLLATERAL OR SPOT BAG QUANTITY */}
            <div className="space-y-2">
              {appMode === 'hedge' ? (
                <>
                  <div className="flex items-center justify-between">
                    <label className="text-xs font-mono uppercase text-[#94A3B8] font-semibold">
                      STEP 3 // {asset.ticker} SHARES TO INSURE OVERNIGHT
                    </label>
                    <button
                      onClick={() => setSpotSharesToHedge(asset.spotBalance)}
                      className="text-[11px] font-mono text-[#F5A623] hover:underline"
                    >
                      Wallet Balance: {asset.spotBalance} {asset.ticker}
                    </button>
                  </div>

                  <div className="bg-[#08090C] border border-[#1E222D] p-3 flex items-center justify-between">
                    <div>
                      <input
                        type="number"
                        min="1"
                        max="10000"
                        value={spotSharesToHedge}
                        onChange={(e) =>
                          setSpotSharesToHedge(Math.max(1, Number(e.target.value) || 0))
                        }
                        className="bg-transparent text-xl font-mono font-bold text-white focus:outline-none w-28"
                      />
                      <div className="text-[11px] font-mono text-[#64748B]">
                        Spot Bag Value: $
                        {(spotSharesToHedge * asset.closePrice).toLocaleString('en-US', {
                          minimumFractionDigits: 2,
                          maximumFractionDigits: 2
                        })}
                      </div>
                    </div>
                    <div className="text-right">
                      <span className="text-xs font-mono font-bold px-2 py-1 bg-[#151922] border border-[#262B38] text-white">
                        {asset.ticker} SHARES
                      </span>
                      <div className="text-[11px] font-mono text-[#F5A623] mt-1">
                        Insurance Cost: ${tradeMetrics.activeCollateral} USDC
                      </div>
                    </div>
                  </div>
                </>
              ) : (
                <>
                  <div className="flex items-center justify-between">
                    <label className="text-xs font-mono uppercase text-[#94A3B8] font-semibold">
                      STEP 3 // COLLATERAL PREMIUM (MAX LOSS CAP)
                    </label>
                    <span className="text-[11px] font-mono text-[#00F59B]">
                      Zero Liquidation Risk
                    </span>
                  </div>

                  <div className="bg-[#08090C] border border-[#1E222D] p-3">
                    <div className="flex items-center justify-between">
                      <input
                        type="number"
                        min="10"
                        max="50000"
                        value={collateralUsdc}
                        onChange={(e) =>
                          setCollateralUsdc(Math.max(10, Number(e.target.value) || 0))
                        }
                        className="bg-transparent text-xl font-mono font-bold text-white focus:outline-none w-32"
                      />
                      <span className="text-xs font-mono font-bold px-2 py-1 bg-[#151922] border border-[#262B38] text-[#CBD5E1]">
                        USDC
                      </span>
                    </div>

                    <div className="flex items-center gap-1.5 mt-2.5">
                      {[100, 250, 500, 1000, 2500].map((amt) => (
                        <button
                          key={amt}
                          onClick={() => setCollateralUsdc(amt)}
                          className={`flex-1 py-1 text-xs font-mono border transition-all ${
                            collateralUsdc === amt
                              ? 'bg-[#00F59B]/15 border-[#00F59B] text-[#00F59B] font-bold'
                              : 'bg-[#0E1118] border-[#1E222D] text-[#8B95A5] hover:text-white'
                          }`}
                        >
                          ${amt}
                        </button>
                      ))}
                    </div>
                  </div>
                </>
              )}
            </div>

            {/* ZERO-JARGON PAYOFF TELEMETRY BOX */}
            <div className="bg-[#08090C] border border-[#1E222D] p-3.5 space-y-2.5 font-mono text-xs">
              <div className="flex items-center justify-between text-[#8B95A5]">
                <span>Notional {asset.ticker} Exposure</span>
                <span className="text-white font-semibold">
                  {tradeMetrics.effectiveShares.toFixed(1)} {asset.ticker} ($
                  {tradeMetrics.insuredNotionalUsd.toLocaleString('en-US', {
                    maximumFractionDigits: 0
                  })}
                  )
                </span>
              </div>

              <div className="flex items-center justify-between text-[#8B95A5]">
                <span>Implied Gap Leverage</span>
                <span className="text-[#00F59B] font-bold bg-[#00F59B]/10 px-1.5 py-0.5 border border-[#00F59B]/30">
                  {tradeMetrics.impliedLeverage}x EFFECTIVE
                </span>
              </div>

              <div className="flex items-center justify-between text-[#8B95A5]">
                <span>09:30 AM Breakeven Open</span>
                <span className="text-white font-semibold">
                  {strategy === 'CALL' &&
                    `$${tradeMetrics.upperBreakeven.toFixed(2)} (+${tradeMetrics.upperBreakevenPct.toFixed(
                      2
                    )}%)`}
                  {strategy === 'PUT' &&
                    `$${tradeMetrics.lowerBreakeven.toFixed(2)} (${tradeMetrics.lowerBreakevenPct.toFixed(
                      2
                    )}%)`}
                  {strategy === 'STRADDLE' &&
                    `$${tradeMetrics.lowerBreakeven.toFixed(2)} or $${tradeMetrics.upperBreakeven.toFixed(
                      2
                    )}`}
                </span>
              </div>

              <div className="flex items-center justify-between text-[#8B95A5]">
                <span>Max Possible Overnight Loss</span>
                <span className="text-[#F8FAFC]">
                  ${tradeMetrics.activeCollateral.toFixed(2)} USDC (Capped)
                </span>
              </div>

              <div className="pt-2 border-t border-[#1E222D] flex items-center justify-between">
                <div>
                  <div className="text-[10px] uppercase text-[#64748B]">
                    {appMode === 'hedge'
                      ? `BAG VALUE AT ${projectedGapPct}% OPEN`
                      : `EST. PAYOUT AT ${projectedGapPct >= 0 ? '+' : ''}${projectedGapPct}% OPEN`}
                  </div>
                  <div
                    className={`text-sm font-bold mt-0.5 ${
                      tradeMetrics.netProfit > 0 ? 'text-[#00F59B]' : 'text-[#94A3B8]'
                    }`}
                  >
                    {appMode === 'hedge' ? (
                      <span>
                        Unhedged: ${tradeMetrics.spotUnhedgedPnL.toFixed(0)} →{' '}
                        <strong className="text-[#00F59B]">
                          Insured: ${tradeMetrics.hedgedCombinedPnL.toFixed(0)}
                        </strong>
                      </span>
                    ) : (
                      <span>
                        ${tradeMetrics.grossPayout.toFixed(2)} USDC (
                        {tradeMetrics.netProfit >= 0 ? '+' : ''}
                        ${tradeMetrics.netProfit.toFixed(2)} Net)
                      </span>
                    )}
                  </div>
                </div>
                <span
                  className={`text-xs font-bold px-2 py-1 border ${
                    tradeMetrics.roiMultiple >= 1
                      ? 'bg-[#00F59B]/15 border-[#00F59B] text-[#00F59B]'
                      : 'bg-[#151922] border-[#262B38] text-[#8B95A5]'
                  }`}
                >
                  {tradeMetrics.roiMultiple.toFixed(1)}x
                </span>
              </div>
            </div>
          </div>

          {/* CTA Action Button Footer */}
          <div className="p-4 lg:p-5 pt-0">
            <button
              onClick={handleMintPosition}
              className={`w-full py-3.5 px-4 font-mono font-bold text-sm uppercase tracking-wider transition-all flex items-center justify-center gap-2 cursor-pointer ${
                appMode === 'hedge'
                  ? 'bg-[#F5A623] hover:bg-[#ffb53b] text-[#08090C] shadow-[0_0_25px_rgba(245,166,35,0.3)]'
                  : strategy === 'PUT'
                  ? 'bg-[#FF3366] hover:bg-[#ff4d79] text-white shadow-[0_0_25px_rgba(255,51,102,0.3)]'
                  : 'bg-[#00F59B] hover:bg-[#26ffaf] text-[#08090C] shadow-[0_0_25px_rgba(0,245,155,0.3)]'
              }`}
            >
              <Zap className="w-4 h-4" />
              {appMode === 'hedge'
                ? `INSURE ${spotSharesToHed