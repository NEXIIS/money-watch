import { useState } from 'react';
import { supabase } from '../lib/supabase';
import { Lock, Mail, User, Loader2, ArrowRight } from 'lucide-react';

export function Auth() {
  const [loading, setLoading] = useState(false);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [username, setUsername] = useState('');
  const [isSignUp, setIsSignUp] = useState(false);
  const [message, setMessage] = useState<{ type: 'error' | 'success'; text: string } | null>(null);

  const handleAuth = async (e: React.FormEvent) => {
    e.preventDefault();
    setMessage(null);

    // Cheap client-side guards so obvious mistakes never hit the network.
    const trimmedEmail = email.trim();
    if (!trimmedEmail || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(trimmedEmail)) {
      setMessage({ type: 'error', text: 'Enter a valid email address.' });
      return;
    }
    // Supabase enforces this too, but a round trip is slow and the error is vague.
    if (password.length < 6) {
      setMessage({ type: 'error', text: 'Password must be at least 6 characters.' });
      return;
    }
    if (isSignUp && !username.trim()) {
      setMessage({ type: 'error', text: 'Pick a username.' });
      return;
    }

    setLoading(true);

    // If signing up, we attach the username to their metadata!
    const { data, error } = isSignUp
      ? await supabase.auth.signUp({
          email: trimmedEmail,
          password,
          options: {
            data: { username: username.trim() } // Save the custom username
          }
        })
      : await supabase.auth.signInWithPassword({ email: trimmedEmail, password });

    if (error) {
      setLoading(false);
      // "already registered" is a dead end for this screen: signing in is the
      // only way forward, so say so instead of echoing the raw GoTrue message.
      if (/already (registered|exists)/i.test(error.message)) {
        setMessage({
          type: 'error',
          text: 'That email already has an account. Switch to Sign in.',
        });
        setIsSignUp(false);
      } else {
        setMessage({ type: 'error', text: error.message });
      }
      return;
    }

    // A returned session means the user is already authenticated. App's
    // onAuthStateChange swaps the view for us, so don't paint a message that
    // would flash on screen for a few frames. Only report the
    // confirmation-required case, which is the one that needs the user to act.
    if (isSignUp && !data.session) {
      setMessage({
        type: 'success',
        text: 'Account created. Check your email for the confirmation link, then sign in.',
      });
    }

    setLoading(false);
    setPassword('');
  };

  return (
    <div className="min-h-screen bg-slate-950 flex items-center justify-center p-4">
      <div className="w-full max-w-md">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-3xl bg-blue-600 shadow-2xl shadow-blue-600/20">
            <Lock size={32} className="text-white" />
          </div>
          <h1 className="text-2xl font-bold text-white">Welcome to Money-Watch</h1>
          <p className="text-slate-400 text-sm mt-2">
            {isSignUp ? 'Create your secure account' : 'Sign in to manage your vault'}
          </p>
        </div>

        <div className="rounded-3xl border border-slate-800 bg-slate-900/50 p-8 backdrop-blur-xl shadow-xl">
          <form onSubmit={handleAuth} className="space-y-5">
            
            {isSignUp && (
              <div>
                <label className="block text-xs font-medium uppercase tracking-wider text-slate-500 mb-2">Username</label>
                <div className="relative">
                  <User className="absolute left-3.5 top-1/2 -translate-y-1/2 text-slate-500" size={18} />
                  <input
                    type="text"
                    required={isSignUp}
                    autoComplete="username"
                    value={username}
                    onChange={(e) => setUsername(e.target.value)}
                    className="w-full rounded-2xl bg-slate-800 border border-slate-700 pl-11 pr-4 py-3.5 text-white placeholder-slate-600 focus:outline-none focus:border-blue-500/50 transition"
                    placeholder="e.g. Satoshi"
                  />
                </div>
              </div>
            )}

            <div>
              <label className="block text-xs font-medium uppercase tracking-wider text-slate-500 mb-2">Email Address</label>
              <div className="relative">
                <Mail className="absolute left-3.5 top-1/2 -translate-y-1/2 text-slate-500" size={18} />
                <input
                  type="email"
                  required
                  autoComplete="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="w-full rounded-2xl bg-slate-800 border border-slate-700 pl-11 pr-4 py-3.5 text-white placeholder-slate-600 focus:outline-none focus:border-blue-500/50 transition"
                  placeholder="you@gmail.com"
                />
              </div>
            </div>

            <div>
              <label className="block text-xs font-medium uppercase tracking-wider text-slate-500 mb-2">Password</label>
              <div className="relative">
                <Lock className="absolute left-3.5 top-1/2 -translate-y-1/2 text-slate-500" size={18} />
                <input
                  type="password"
                  required
                  minLength={6}
                  autoComplete={isSignUp ? 'new-password' : 'current-password'}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="w-full rounded-2xl bg-slate-800 border border-slate-700 pl-11 pr-4 py-3.5 text-white placeholder-slate-600 focus:outline-none focus:border-blue-500/50 transition"
                  placeholder="••••••••"
                />
              </div>
            </div>

            {message && (
              <div className={`rounded-xl p-4 text-sm ${message.type === 'error' ? 'bg-red-500/10 text-red-400 border border-red-500/20' : 'bg-emerald-500/10 text-emerald-400 border border-emerald-500/20'}`}>
                {message.text}
              </div>
            )}

            <button
              disabled={loading}
              className="group relative w-full overflow-hidden rounded-2xl bg-blue-600 py-4 font-semibold text-white transition hover:bg-blue-500 disabled:opacity-50"
            >
              <div className="relative z-10 flex items-center justify-center gap-2">
                {loading ? <Loader2 className="animate-spin" size={20} /> : (
                  <>
                    {isSignUp ? 'Create Account' : 'Sign In'}
                    <ArrowRight size={18} className="group-hover:translate-x-1 transition-transform" />
                  </>
                )}
              </div>
            </button>
          </form>

          <div className="mt-8 text-center">
            <button
              onClick={() => setIsSignUp(!isSignUp)}
              className="text-sm text-slate-400 hover:text-white transition"
            >
              {isSignUp ? 'Already have an account? Sign in' : "Don't have an account? Sign up"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}