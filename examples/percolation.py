# Percolation example based on Herrmann & Bottcher, Computational Statistical Physics, 2021
# Uses the burning method (2.3.1) for the cell simulation
# Marks clusters with the Hoshen-Kopelman algorithm (2.3.4) (Fig. 2.9)

import support.random

def main():

    ### Parameters ###
    GRID_LEN: int = 40
    PROB_FILL: float = 0.61 # fill probability
    MAX_STEP: int = 1000 # upper bound on burning steps

    ### Program ###

    grid: array[int, :, :]  # 0=empty, 1=occupied, >=2=burning label
    allocate(grid, GRID_LEN, GRID_LEN)

    grid_z_flat: array[float, :]  # flat random values for threshold
    allocate(grid_z_flat, GRID_LEN*GRID_LEN)
    random_fill(grid_z_flat)
    grid_z: array[float, :, :]  # random values reshaped to 2D
    grid_z = reshape(grid_z_flat, [GRID_LEN, GRID_LEN])

    # Label occupied=1, empty=0; top-row occupied cells start fire at label 2
    for i in range(GRID_LEN):
        for j in range(GRID_LEN):
            if grid_z[i,j] < PROB_FILL:
                if i == 0:
                    grid[i,j] = 2
                else:
                    grid[i,j] = 1
            else:
                grid[i,j] = 0

    # Burning method: each step spreads label t to unburned (=1) neighbors as t+1
    t: int = 2
    percolates: bool = False
    path_len: int = 0
    changed: bool = True
    step: int = 0
    while changed and step < MAX_STEP:
        changed = False
        for i in range(GRID_LEN):
            for j in range(GRID_LEN):
                if grid[i,j] == t:
                    if i > 0 and grid[i-1,j] == 1:
                        grid[i-1,j] = t + 1
                        changed = True
                    if i < GRID_LEN-1 and grid[i+1,j] == 1:
                        grid[i+1,j] = t + 1
                        changed = True
                    if j > 0 and grid[i,j-1] == 1:
                        grid[i,j-1] = t + 1
                        changed = True
                    if j < GRID_LEN-1 and grid[i,j+1] == 1:
                        grid[i,j+1] = t + 1
                        changed = True
        # check if fire reached bottom row; path length = latest label - 1
        for j in range(GRID_LEN):
            if grid[GRID_LEN-1, j] == t + 1:
                percolates = True
                path_len = t  # (t+1) - 1
        if percolates:
            break
        t = t + 1
        step = step + 1

    print("Steps: ", step)

    # Hoshen-Kopelman algorithm: label clusters on original occupancy
    MAX_CLUSTERS: int = GRID_LEN * GRID_LEN + 2
    cluster_id: array[int, :, :]  # cluster label per site
    allocate(cluster_id, GRID_LEN, GRID_LEN)
    M: array[int, :]  # cluster mass; negative entry = pointer to true root label
    allocate(M, MAX_CLUSTERS)
    for k in range(MAX_CLUSTERS):
        M[k] = 0

    k_curr: int = 1  # incremented before each new-cluster assignment
    top_k: int = 0
    left_k: int = 0
    k0: int = 0
    k1: int = 0
    k2: int = 0

    for i in range(GRID_LEN):
        for j in range(GRID_LEN):
            if grid_z[i,j] >= PROB_FILL:
                cluster_id[i,j] = 0  # empty site
            else:
                top_k = 0
                left_k = 0
                if i > 0:
                    top_k = cluster_id[i-1,j]
                if j > 0:
                    left_k = cluster_id[i,j-1]
                if top_k == 0 and left_k == 0:
                    # new cluster
                    k_curr = k_curr + 1
                    M[k_curr] = 1
                    cluster_id[i,j] = k_curr
                elif top_k != 0 and left_k == 0:
                    k0 = top_k
                    while M[k0] < 0:
                        k0 = -M[k0]
                    cluster_id[i,j] = k0
                    M[k0] = M[k0] + 1
                elif top_k == 0 and left_k != 0:
                    k0 = left_k
                    while M[k0] < 0:
                        k0 = -M[k0]
                    cluster_id[i,j] = k0
                    M[k0] = M[k0] + 1
                else:
                    # both neighbors occupied; find roots and merge
                    k1 = top_k
                    while M[k1] < 0:
                        k1 = -M[k1]
                    k2 = left_k
                    while M[k2] < 0:
                        k2 = -M[k2]
                    if k1 == k2:
                        cluster_id[i,j] = k1
                        M[k1] = M[k1] + 1
                    else:
                        cluster_id[i,j] = k1
                        M[k1] = M[k1] + M[k2] + 1
                        M[k2] = -k1  # k2 now points to k1

    # Find largest cluster size
    largest: int = 0
    for k in range(2, k_curr+1):
        if M[k] > largest:
            largest = M[k]

    # Build float grid of root-resolved cluster labels for imshow (Fig. 2.9)
    cluster_vis: array[float, :, :]
    allocate(cluster_vis, GRID_LEN, GRID_LEN)
    k_root: int = 0
    for i in range(GRID_LEN):
        for j in range(GRID_LEN):
            k_root = cluster_id[i,j]
            while k_root > 0 and M[k_root] < 0:
                k_root = -M[k_root]
            if k_root == 0:
                cluster_vis[i,j] = 0.0
            else:
                cluster_vis[i,j] = (k_root % 13 + 1) * 1.0  # cycle colors to distinguish neighbors

    imshow(cluster_vis, f"percolation_clusters_p{PROB_FILL:.2f}.png", f"Percolation Clusters (p={PROB_FILL:.2f})")

    if percolates:
        print("Percolates: yes, shortest path length:", path_len)
    else:
        print("Percolates: no")
    print("Largest cluster size:", largest)
