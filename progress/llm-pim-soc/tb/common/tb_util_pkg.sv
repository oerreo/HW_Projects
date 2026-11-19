// tb_util_pkg: shared self-checking helpers for module testbenches.
//
// Usage pattern:
//   tb_checker chk = new("data");
//   if (got === exp) chk.pass(); else chk.fail($sformatf("..."));
//   ...
//   tb_final_report('{chk_a, chk_b});   // prints per-checker counts and
//                                       // "TB_RESULT: PASS" or "TB_RESULT: FAIL"
// sim/run.sh treats a run as passed only if the log contains
// "TB_RESULT: PASS" and no simulator error lines.
package tb_util_pkg;

  class tb_checker;
    string           name;
    longint unsigned n_checks;
    longint unsigned n_mismatch;
    int              max_print;

    function new(string name, int max_print = 10);
      this.name       = name;
      this.max_print  = max_print;
      this.n_checks   = 0;
      this.n_mismatch = 0;
    endfunction

    function void pass();
      n_checks++;
    endfunction

    // msg describes inputs, expected and actual values of the failing check.
    function void fail(string msg);
      n_checks++;
      n_mismatch++;
      if (n_mismatch <= longint'(max_print))
        $display("MISMATCH [%s] #%0d @%0t: %s", name, n_mismatch, $time, msg);
      else if (n_mismatch == longint'(max_print) + 1)
        $display("MISMATCH [%s] further mismatches not printed", name);
    endfunction

    function void report();
      $display("CHECKS [%s]: checks=%0d mismatches=%0d", name, n_checks, n_mismatch);
    endfunction
  endclass

  typedef tb_checker tb_checker_q[$];

  // Prints all checkers and the final verdict. A checker with zero checks
  // counts as a failure so that a broken stimulus loop cannot pass silently.
  function automatic bit tb_final_report(tb_checker_q chks);
    bit ok = 1'b1;
    foreach (chks[i]) begin
      chks[i].report();
      if (chks[i].n_mismatch != 0 || chks[i].n_checks == 0) ok = 1'b0;
    end
    $display("TB_RESULT: %s", ok ? "PASS" : "FAIL");
    return ok;
  endfunction

  // Seed the calling process RNG from +SEED=<n> (default 1) and return it.
  function automatic int unsigned tb_seed_from_plusarg();
    int unsigned seed = 1;
    void'($value$plusargs("SEED=%d", seed));
    process::self().srandom(seed);
    return seed;
  endfunction

endpackage
