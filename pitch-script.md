# GAP — pitch script

Said out loud, the way you'd explain it to someone sitting across from you.
Flat. No pitch voice. ~6 minutes.

---

## 1. What the problem actually is

Tokenized stocks trade all weekend. The real stock doesn't.

So what happens over a weekend is that the token price moves on liquidity, not
on anything real. There's barely anyone trading. A few orders push it around.
It's not the market deciding what the stock is worth, because the market that
decides that is closed.

Then Monday opens, and the price snaps to wherever the actual stock opened.

And that's the problem. Traders holding these tokens with leverage — on
whatever platform they're using — get liquidated the moment Monday opens. Not
because they were wrong. Because the price moved all at once, at an hour they
couldn't do anything about, to a level that wasn't knowable on Friday.

That's a very real problem in tokenized stocks right now. Everyone holding
through a weekend is carrying that risk and there's nothing available to them
that takes it away.

## 2. What we're building

GAP is a platform that takes that weekend gap and makes it something you can
trade instead of something that happens to you.

Two sides to it.

On one side, the trader. Instead of holding leverage into the weekend and
hoping, you buy an option. You pay a premium up front and that's the most you
can lose. Monday can open wherever it wants. You don't get liquidated, because
there's nothing to liquidate.

On the other side, the maker. There's a lot of tokenized stock just sitting in
wallets over the weekend doing nothing. The market's shut, the stock isn't
moving, and the person holding it earns zero for those sixty-odd hours. We let
them write these options against that stock and earn on it.

So the stock that was idle anyway is now making fees, and the trader who was
going to get liquidated has a way out. Both sides get something.

## 3. What the trader is actually buying

It's an option with an upside and a floor.

Say the stock's at 210. I think it goes up over the weekend. I pay a five
dollar premium for the upside. Monday it opens at 220 — that's ten dollars of
move. I paid five for it, so I keep five.

And if it goes the other way, I lose the five dollars. That's it. That's the
whole downside. I knew the number before I bought it.

Same thing works in reverse. If I'm already holding the stock and I'm worried
about Monday, I buy the floor. Monday gaps down, I'm covered down to my level,
and the premium is what it cost me.

That's the shape of it. The upside stays open, the bottom is fixed, and you
pay a known amount for that.

The premium itself is Black-Scholes. We compute it on chain at the moment of
the trade — the spot price, the time left to expiry, the volatility. It's not
a number we hand you. It comes out of the contract.

## 4. How the maker side works, and why Aqua

Here's the part that makes the maker side worth doing.

Normally if you want to write options you have to lock your stock up somewhere.
Deposit it into a vault, it sits there all weekend, and if nobody trades you've
locked it for nothing.

We don't do that. With Aqua, the maker keeps the stock in their own wallet.
What they do is commit — they say, I'll write up to this many options on this
stock at this volatility. That commitment costs them nothing. No transfer. The
tokens don't move.

Then when a taker actually shows up and buys, that's when everything happens,
in one transaction. The stock comes out of the maker's wallet, the option gets
created against it, and the premium goes back to the maker.

If nobody buys all weekend, nothing happened at all. Their tokens never left.

That's the whole reason the maker side is realistic. You're not asking someone
to strand capital on a maybe. You're asking them to put up a quote, and they
get paid when it's taken.

Aqua is what makes that possible. It's a commitment ledger — makers record what
they've promised, custody stays with them, and the available size of a quote is
just what's on that ledger. There's no order server, no signatures, no relayer
in the middle. The trade goes through 1inch's router, and our pricing runs
inside the swap itself, which is how the premium gets computed mid-trade
instead of quoted beforehand.

We didn't build any of that. What we built is the option.

## 5. Where that leaves both sides

The taker never gets liquidated. The worst case is the premium, and they knew
it on Friday.

The maker earns on stock that was doing nothing anyway. Over enough weekends,
that's real yield on a position they were holding regardless, in a window where
the market is shut and the asset would otherwise just sit there.

That's the trade we're making possible. Right now the weekend gap is something
everybody just absorbs. We're turning it into something with two sides and a
price.

## 6. What's running

It's deployed on Base Sepolia and it works end to end.

Upside and floor out of the same desk, with the collateral kept separate. The
full cycle happens on chain — the maker commits, someone buys, someone sells
back, it expires, holders exercise, the maker redeems what's left — and the
books net to zero. There's a UI, you can do the whole thing from a wallet.
Nothing in it is faked.

---

## Delivery notes

- Section 1 is the whole pitch. If they only hear one part, it's "Monday opens
  and you're liquidated at a price that didn't exist on Friday."
- Say the 210 / 220 / 5 example slowly. Don't add a second example.
- Don't say "options protocol." Say what it does.
- Short on time: cut §5. Everything in it is implied by 2 and 4.

## Questions you'll get

**Who's writing these?** Anyone already holding the stock. The commitment costs
nothing until it's filled, so the bar is low. Day one it's a desk; nothing
stops that from widening.

**What if the maker's wallet is empty when someone buys?** The trade reverts.
We check the committed balance before pulling anything, so it fails cleanly.

**Why not just use a perp?** The perp is the thing that liquidated you in
section 1. The point of this is that there's no margin to maintain over a
weekend you're asleep for.

**Where's the price coming from if the market is closed?** The pool the token
actually trades in. We're not claiming to know Monday's open — we're pricing
the uncertainty between Friday and Monday, which is what volatility is.

**Can the settlement price be manipulated?** It's averaged over a window after
expiry instead of read at one instant, so you'd have to hold a price, not print
one.
