/* ============================================================================
   Pitch — the deck, as a page of the app rather than a PDF beside it.

   Built on the shape of the live Weekend Options deck (wknd.davinciin.xyz/
   pitch): one idea per slide, a headline that is a sentence rather than a
   label, and a drawing carrying the argument instead of a bullet list. Two
   things change.

   The name: here the product is GAP, the overnight-gap desk this app is.
   Contract names stay as they are — the core is the ported Weekend Options
   protocol, and a diagram that renamed its contracts would not match the
   deployment it describes.

   The argument: the original pitch was written for a chain with no options
   venue, so it had to argue for building one. On Aqua the venue already
   exists, so everything the old deck sold as "what we built" — book, custody,
   settlement, authorisation — is something this one deleted instead.
   ========================================================================= */

import { useEffect, useRef, useState, type ReactNode } from 'react'
import { ArrowLeft } from 'lucide-react'
import { ArchitectureDiagram } from './ArchitectureDiagram'
import { GapOutcomeChart } from './GapOutcomeChart'
import { UpsidePayoff, FloorPayoff } from './PayoffDiagram'
import './pitch.css'

const EXPLORER = 'https://sepolia.basescan.org/tx/'

/** The proven series-1 lifecycle, from the handoff. Every one confirmed status 0x1. */
const LIFECYCLE: [string, string][] = [
  ['buy (router.swap)', '0xfa495ee82fe2f8f05c77307b77d8b3211d2c128909972cc6945cf7d950b63de8'],
  ['sell back into the bid', '0xd60e6314c8882aa5aecaa26c3f3290c478f35d100c83f56c5b081bc9e3f2cd29'],
  ['exercise — no oracle read', '0x04e67cab227d414e9af85f226a00c6f9110e2a3cd9a8917921d67839d3220977'],
  ['recordSettlement', '0x84e735a767a84639492e983f1cdd02eb8291ee421d52317d727bc94490e00bf3'],
  ['settle', '0x5e1b6850354cb9ed3dc605d57389936e99a75b9e947d23cba6ac0c71b3a9950c'],
  ['redeemFor (holder paid)', '0xa41024c2cc2405df469d451fe0be5e54822493fbc85a06ebd690a65e759ff851'],
  ['claimFor (writer paid)', '0x7bf7fa8096f004f99b9ad12b700201ce180b3763fb565b2a46d252c17415c4ee'],
]

interface Slide {
  /** Short label for the dot rail's tooltip. */
  tag: string
  /** The figure slides need more width than the prose slides. */
  wide?: boolean
  render: ReactNode
}

const SLIDES: Slide[] = [
  {
    tag: 'Title',
    render: (
      <>
        <div className="pd__kicker">GAP · options on 1inch Aqua</div>
        <h1 className="pd__h">
          Never get <span className="pd__up">liquidated.</span>
        </h1>
        <div className="pd__facts">
          <span className="pd__fact">Base Sepolia</span>
          <span className="pd__fact">
            <b>207</b> tests
          </span>
          <span className="pd__fact">
            <b>0</b> opcode forks
          </span>
        </div>
      </>
    ),
  },
  {
    tag: 'The gap',
    wide: true,
    render: (
      <>
        <div className="pd__kicker">The problem</div>
        <h2 className="pd__h pd__h--sm">
          Stale price. <span className="pd__down">Sudden gap.</span> Everyone liquidated.
        </h2>
        {/* The real chart, not a redraw. It is a dark screenshot on a light
            deck, so it gets a dark frame rather than being dropped onto the
            page — that reads as a terminal someone pulled up, which is what
            it is. */}
        <figure className="pd__shot">
          <img
            src="charts/qqqx-gap.png"
            alt="QQQx hourly: the price drifts flat through the closed weekend near 212, then the equity market reopens and it reprices down through 203."
            width={1760}
            height={1037}
          />
          <figcaption>
            QQQx · 1h · flat through the shut weekend, then <b>212.82 → 203.61</b>
          </figcaption>
        </figure>
      </>
    ),
  },
  {
    tag: 'Products',
    wide: true,
    render: (
      <>
        <div className="pd__kicker">Two products, one axis</div>
        <h2 className="pd__h pd__h--sm">
          <span className="pd__up">Upside</span> to ride. <span className="pd__down">Floor</span> to
          survive.
        </h2>
        <div className="pd__pair">
          <div className="pd__fig">
            <UpsidePayoff />
          </div>
          <div className="pd__fig">
            <FloorPayoff />
          </div>
        </div>
      </>
    ),
  },
  {
    tag: 'The difference',
    wide: true,
    render: (
      <>
        <div className="pd__kicker">Same 12% gap, three ways to hold it</div>
        <h2 className="pd__h pd__h--sm">
          <span className="pd__down">Perp zero.</span> <span className="pd__up">Floor safe.</span>
        </h2>
        <div className="pd__fig">
          <GapOutcomeChart />
        </div>
      </>
    ),
  },
  {
    tag: 'The flip',
    render: (
      <>
        <div className="pd__kicker">The flip</div>
        <h2 className="pd__h">The venue already exists.</h2>
        <table className="pd__flip">
          <tbody>
            <tr>
              <td>Order book</td>
              <td>Aqua&rsquo;s ledger</td>
            </tr>
            <tr>
              <td>Custody</td>
              <td>The maker&rsquo;s wallet</td>
            </tr>
            <tr>
              <td>Matching engine</td>
              <td>
                <code>AquaSwapVMRouter</code>
              </td>
            </tr>
            <tr>
              <td>Signed quotes</td>
              <td>Shipping on chain</td>
            </tr>
            <tr>
              <td>Minting, then listing</td>
              <td>Minting inside the fill</td>
            </tr>
          </tbody>
        </table>
      </>
    ),
  },
  {
    tag: 'Architecture',
    wide: true,
    render: (
      <>
        <div className="pd__kicker">Teal is 1inch as deployed · violet is ours</div>
        <h2 className="pd__h pd__h--sm">Ship. Fill. Expire.</h2>
        <div className="pd__arch">
          <ArchitectureDiagram />
        </div>
      </>
    ),
  },
  {
    tag: 'The order',
    render: (
      <>
        <div className="pd__kicker">The whole quote, as bytecode</div>
        <h2 className="pd__h">An option is an order.</h2>
        <pre className="pd__code">
          <span className="k">Deadline</span>
          {' + '}
          <span className="k">Salt</span>
          {' + '}
          <span className="k">RequireMinRate</span>
          {' + '}
          <span className="k">Extruction</span>
          {'(pricer)\n\n'}
          {'hash(order) == Aqua.strategyHash'}
        </pre>
        <div className="pd__facts">
          <span className="pd__fact">No new opcode</span>
          <span className="pd__fact">No fork edit</span>
          <span className="pd__fact">No router patch</span>
        </div>
      </>
    ),
  },
  {
    tag: 'No oracle',
    render: (
      <>
        <div className="pd__kicker">Why there is nothing to liquidate</div>
        <h2 className="pd__h">Exercise reads no oracle.</h2>
        <div className="pd__stats">
          <div className="pd__stat">
            <div className="pd__stat__v">CALL</div>
            <div className="pd__stat__k">Writer locks the stock</div>
          </div>
          <div className="pd__stat">
            <div className="pd__stat__v">PUT</div>
            <div className="pd__stat__k">Writer locks the strike</div>
          </div>
          <div className="pd__stat">
            <div className="pd__stat__v">∅</div>
            <div className="pd__stat__k">Margin, and anything to liquidate</div>
          </div>
        </div>
      </>
    ),
  },
  {
    tag: 'Proven',
    render: (
      <>
        <div className="pd__kicker">Base Sepolia · every leg confirmed</div>
        <h2 className="pd__h">Proven on chain.</h2>
        <table className="pd__tx">
          <tbody>
            {LIFECYCLE.map(([step, tx]) => (
              <tr key={tx}>
                <td>{step}</td>
                <td>
                  <a href={EXPLORER + tx} target="_blank" rel="noreferrer">
                    {tx.slice(0, 18)}…{tx.slice(-6)}
                  </a>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="pd__facts">
          <span className="pd__fact">
            <b>207</b> tests green
          </span>
          <span className="pd__fact">
            After <b>claimFor</b>: 0 held
          </span>
        </div>
      </>
    ),
  },
  {
    tag: 'Close',
    render: (
      <>
        <div className="pd__kicker">GAP · on 1inch Aqua</div>
        <h2 className="pd__h">The option is the order.</h2>
        <div className="pd__facts">
          <span className="pd__fact">
            weekendOptions <b>0x7031…Ce4f</b>
          </span>
          <span className="pd__fact">
            desk <b>0xc05D…1B0C</b>
          </span>
          <span className="pd__fact">
            router <b>0x0923…3B72</b>
          </span>
          <span className="pd__fact">
            aqua <b>0x1E52…cd1f</b>
          </span>
        </div>
      </>
    ),
  },
]

/* -- page ------------------------------------------------------------------ */

export default function Pitch() {
  const deckRef = useRef<HTMLDivElement>(null)
  const [at, setAt] = useState(0)
  // The index also lives in a ref: a key held down fires faster than smooth
  // scrolling settles, so the handler must read where we are *going*, not the
  // last state React committed, or every press after the first is a no-op.
  const atRef = useRef(0)
  // And while a programmatic scroll is in flight the observer sweeps through
  // every slide in between. Those sightings move the dots but must NOT move
  // the target, or the next keypress recomputes from a slide we are only
  // passing over.
  const navigating = useRef(false)
  const navTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)

  // One observer over the sections beats a scroll handler doing maths: the
  // browser already knows which slide is centred.
  useEffect(() => {
    const deck = deckRef.current
    if (!deck) return
    const sections = Array.from(deck.querySelectorAll('section'))
    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          // `is-live` gates every animation in pitch.css, so motion only runs on
          // the slide being looked at — and replays when you page back to it.
          e.target.classList.toggle('is-live', e.isIntersecting)
          if (!e.isIntersecting) continue
          const i = sections.indexOf(e.target as HTMLElement)
          if (!navigating.current) atRef.current = i
          setAt(i)
        }
      },
      { root: deck, threshold: 0.55 },
    )
    sections.forEach((s) => io.observe(s))
    sections[0]?.classList.add('is-live')

    // scrollend is the real signal; the timeout in goto covers browsers
    // without it.
    const settled = () => {
      navigating.current = false
    }
    deck.addEventListener('scrollend', settled)
    return () => {
      io.disconnect()
      deck.removeEventListener('scrollend', settled)
    }
  }, [])

  const goto = (i: number) => {
    const deck = deckRef.current
    if (!deck) return
    const clamped = Math.max(0, Math.min(SLIDES.length - 1, i))
    atRef.current = clamped
    navigating.current = true
    clearTimeout(navTimer.current)
    navTimer.current = setTimeout(() => {
      navigating.current = false
    }, 900)
    deck.querySelectorAll('section')[clamped]?.scrollIntoView({ block: 'start' })
  }

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const k = e.key
      if (k === 'ArrowRight' || k === 'ArrowDown' || k === 'PageDown' || k === ' ') {
        e.preventDefault()
        goto(atRef.current + 1)
      } else if (k === 'ArrowLeft' || k === 'ArrowUp' || k === 'PageUp') {
        e.preventDefault()
        goto(atRef.current - 1)
      } else if (k === 'Home') {
        e.preventDefault()
        goto(0)
      } else if (k === 'End') {
        e.preventDefault()
        goto(SLIDES.length - 1)
      }
    }
    addEventListener('keydown', onKey)
    return () => removeEventListener('keydown', onKey)
  }, [])

  return (
    <>
      <div className="pd__chrome pd__chrome--tl">
        <a className="pd__back" href="#trade">
          <ArrowLeft size={14} /> Desk
        </a>
      </div>

      <nav className="pd__rail" aria-label="Slides">
        {SLIDES.map((s, i) => (
          <button
            key={s.tag}
            className="pd__dot"
            aria-current={i === at}
            aria-label={`Slide ${i + 1}: ${s.tag}`}
            title={s.tag}
            onClick={() => goto(i)}
          />
        ))}
      </nav>

      <div className="pd__chrome pd__chrome--br">
        <span className="pd__counter">
          {String(at + 1).padStart(2, '0')} / {String(SLIDES.length).padStart(2, '0')}
        </span>
      </div>

      <div className="pd" ref={deckRef}>
        {SLIDES.map((s, i) => (
          <section
            key={s.tag}
            className={`pd__slide${i === 0 ? ' pd__slide--title' : ''}${
              s.wide ? ' pd__slide--wide' : ''
            }`}
          >
            {s.render}
          </section>
        ))}
      </div>
    </>
  )
}
