% Subproblem assembly for (tranformed) progressive multigrid Angular Embedding.
%
% ae_mx = ae_subproblem_fold(ae_prob, tol_ichol, transform_flag)
%
% Assemble the vector representation of a multilevel constrained AE problem
% into the matrix representation used by the solver at each subproblem level.
% Optionally tranform the intermediate subproblems by folding weights from
% dropped finer levels into active coarser levels.
%
% See also ae_multigrid, ae_subproblem_extract.
%
% Input:
%    ae_prob        - vector representation of multilevel AE problem
%    tol_ichol      - tolerance for incomplete Cholesky       (default: 2.^-20)
%    transform_flag - use constraints to transform weights?    (default: false)
%
% Output:
%    ae_mx.         - matrices active at each pyramid level in the solver
%       P_arr          - diffusion matrices for use in refinement
%       U_arr          - constraint matrices for use in refinement
%       R_arr          - incomplete Cholesky factorization for constraints
%       Ua_arr         - upper constraint matrices for interpolation
%       Ub_arr         - lower constraint matrices for interpolation
%       Rb_arr         - incomplete Cholesky factorization for interpolation
function ae_mx = ae_subproblem_fold(ae_prob, tol_ichol, transform_flag)
   % default arguments
   opts_def = ae_multigrid('opts');
   if ((nargin < 2) || isempty(tol_ichol))
      tol_ichol = opts_def.tol_ichol;
   end
   if ((nargin < 3) || isempty(transform_flag))
      transform_flag = opts_def.transform_flag;
   end
   % unpack problem data structure
   ne         = ae_prob.ne;
   ne_cum     = ae_prob.ne_cum;
   nu_arr     = ae_prob.nu_arr;
   nu_cum     = ae_prob.nu_cum;
   w_size_cum = ae_prob.w_size_cum;
   u_size_cum = ae_prob.u_size_cum;
   wi_vec     = ae_prob.wi_vec;
   wj_vec     = ae_prob.wj_vec;
   cval_vec   = ae_prob.cval_vec;
   tval_vec   = ae_prob.tval_vec;
   ui_vec     = ae_prob.ui_vec;
   uj_vec     = ae_prob.uj_vec;
   uval_vec   = ae_prob.uval_vec;
   dval_vec   = ae_prob.dval_vec;
   % get number of levels
   nlvls = numel(ae_prob.ne_arr);
   % allocate cell arrays for pyramid-specific matrices
   P_arr  = cell([nlvls 1]);
   U_arr  = cell([nlvls 1]);
   R_arr  = cell([nlvls 1]);
   Ua_arr = cell([nlvls 1]);
   Ub_arr = cell([nlvls 1]);
   Rb_arr = cell([nlvls 1]);
   % initialize weight and degree matrices for full pyramid
   W = sparse(wi_vec, wj_vec, cval_vec.*exp(i.*tval_vec), ne, ne);
   D_sqrt_inv = spdiags(1./sqrt(dval_vec + eps), 0, ne, ne);
   D_sqrt     = spdiags(sqrt(dval_vec + eps),    0, ne, ne);
   % fold pyramid levels from fine to coarse
   for s = nlvls:-1:1
      % compute degree-normalized diffusion matrix
      P_arr{s} = D_sqrt_inv * W * D_sqrt_inv;
      % form constraint matrix
      ui   = ui_vec(1:u_size_cum(s));
      uj   = uj_vec(1:u_size_cum(s));
      uval = uval_vec(1:u_size_cum(s));
      U = sparse(ui, uj, uval, ne_cum(s), nu_cum(s));
      % degree-normalize and factor constraints
      if (isempty(U))
         % no active constraints for current pyramid level
         U_arr{s} = [];
         R_arr{s} = [];
      else
         % degree-normalize constraint matrix
         U = D_sqrt_inv * U;
         % factor constraint product using incomplete Cholesky
         R = cholinc(U' * U, tol_ichol);
         % store active constraints for current pyramid level
         U_arr{s} = U;
         R_arr{s} = R;
      end
      % construct interpolation matrices and fold weight matrix
      if (s > 1)
         % extract incremental constraint matrix
         ui_inc   = ui_vec((u_size_cum(s-1)+1):u_size_cum(s));
         uj_inc   = uj_vec((u_size_cum(s-1)+1):u_size_cum(s));
         uval_inc = uval_vec((u_size_cum(s-1)+1):u_size_cum(s));
         % adjust constraint indices to be incremental
         uj_inc = uj_inc - nu_cum(s-1);
         % break incremental constraint matrix into upper and lower blocks
         nea    = ne_cum(s-1);         % # of elements in coarser pyramid
         neb    = ne_cum(s);           % # of elements in current pyramid
         indsUa = find(ui_inc <= nea); % upper block of U_arr{s}
         indsUb = find(ui_inc > nea);  % lower block of U_arr{s}
         Ua = sparse( ...
            ui_inc(indsUa), uj_inc(indsUa), uval_inc(indsUa), ...
            nea, nu_arr(s) ...
         );
         Ub = sparse( ...
            ui_inc(indsUb) - nea, uj_inc(indsUb), uval_inc(indsUb), ...
            neb - nea, nu_arr(s) ...
         );
         % factor lower constraint block product using incomplete Cholesky
         Rb_arr{s} = cholinc(Ub' * Ub, tol_ichol);
         % form upper and lower diagonal degree transformation matrices
         dval_sqrt_inv = spdiags(D_sqrt_inv, 0);
         dval_sqrt     = spdiags(D_sqrt, 0);
         Da_sqrt_inv   = spdiags(dval_sqrt_inv(1:nea),   0, nea,     nea);
         Db_sqrt       = spdiags(dval_sqrt((nea+1):neb), 0, neb-nea, neb-nea);
         % store degree-normalized incremental constraint blocks
         Ua_arr{s} = Da_sqrt_inv * Ua;
         Ub_arr{s} = Db_sqrt * Ub;
         % check if transforming weights
         if (transform_flag)
            % factor upper constraint block product using incomplete Cholesky
            Ra = cholinc(Ua' * Ua, tol_ichol);
            % break weight matrix into upper and lower blocks
            [wi wj wval] = find(W);
            indsWa = find((wi <= nea) & (wj <= nea)); % W upper diagonal block
            indsWb = find((wi > nea) & (wj > nea));   % W lower diagonal block
            Wa = sparse( ...
               wi(indsWa), wj(indsWa), wval(indsWa), ...
               nea, nea ...
            );
            Wb = sparse( ...
               wi(indsWb) - nea, wj(indsWb) - nea, wval(indsWb), ...
               neb - nea, neb - nea ...
            );
            % transform weight matrix for next coarsest level
            Wt = Ua * (Ra \ (Ra' \ (-Ub' * Wb)));
            Wt = Ua * (Ra \ (Ra' \ (-Ub' * Wt')));
            W = Wa + Wt';
            % update degree matrix for next coarsest level
            dval = sum(abs(W),2);
            D_sqrt_inv = spdiags(1./sqrt(dval + eps), 0, nea, nea);
            D_sqrt     = spdiags(sqrt(dval + eps),    0, nea, nea);
         else
            % drop current level from weight and degree matrices
            wi   = wi_vec(1:w_size_cum(s-1));
            wj   = wj_vec(1:w_size_cum(s-1));
            cval = cval_vec(1:w_size_cum(s-1));
            tval = tval_vec(1:w_size_cum(s-1));
            dval = dval_vec(1:nea);
            W = sparse(wi, wj, cval.*exp(i.*tval), nea, nea);
            D_sqrt_inv = spdiags(1./sqrt(dval + eps), 0, nea, nea);
            D_sqrt     = spdiags(sqrt(dval + eps),    0, nea, nea);
         end
      else
         % top of pyramid - no iterpolation or folding
         Ua_arr{s} = [];
         Ub_arr{s} = [];
         Rb_arr{s} = [];
      end
   end
   % pack matrices for use by solver
   ae_mx = struct( ...
      'P_arr',  {P_arr}, ...
      'U_arr',  {U_arr}, ...
      'R_arr',  {R_arr}, ...
      'Ua_arr', {Ua_arr}, ...
      'Ub_arr', {Ub_arr}, ...
      'Rb_arr', {Rb_arr} ...
   );
end
