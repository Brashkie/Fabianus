--  SPDX-License-Identifier: GPL-3.0-or-later
package body Quantum_Core with
  SPARK_Mode
is
   function Update (Estimate, Sample : U64) return U64 is
      E : constant U64 := Clamp (Estimate);
      S : constant U64 := Clamp (Sample);
   begin
      return E - E / 8 + S / 8;
   end Update;

   function Quantum_For (Estimate : U64) return U64 is
      E : constant U64 := Effective (Estimate);
   begin
      return U64'Min (Max_Quantum, U64'Max (Min_Quantum, Factor * E));
   end Quantum_For;

   function Slice_For (Remaining, Budget, Quantum, Estimate : U64) return U64 is
      Q : constant U64 := Bounded (Quantum);
   begin
      if Budget >= 2 * Effective (Estimate) then
         return U64'Min (Remaining, Q);
      end if;
      return U64'Max (U64'Min (Remaining, Q), U64'Min (Q, 2 * Effective (Estimate)));
   end Slice_For;

end Quantum_Core;
