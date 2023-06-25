# zan1ling4 | 真零 | (pronounced Jun Ling)
# imports
import numpy as np
import chess
import torch
from torch import nn
from torch import optim
import sqlite3
import matplotlib.pyplot as plt
import tqdm
import torch.nn.init as init
import copy
import pickle
import gc
import subprocess
import psutil
gc.disable()


TEST_PRECISION = 10  # number of games used for test
RAM_USAGE = 75  # RAM usage in %

if torch.cuda.is_available():
    d = torch.device("cuda")
    scaler = GradScaler()
    import torch.cuda
    from torch.cuda.amp import GradScaler  # NEED GPU
elif torch.backends.mps.is_available():
    d = torch.device("mps")
else:
    d = torch.device("cpu")

print("Using: " + str(d))


class Tanh200(nn.Module):
    def __init__(self):
        super(Tanh200, self).__init__()

    def forward(self, x):
        return torch.tanh(x / 200)


class Agent(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(833, 2048,dtype=torch.float32).to(d)
        self.bn1 = nn.BatchNorm1d(2048, dtype=torch.float32).to(d)
        self.dropout1 = nn.Dropout(p=0.45).to(d)
        self.relu = nn.LeakyReLU(0.05).to(d)
        self.layer2 = nn.Linear(2048, 1,dtype=torch.float32).to(d)
        self.dropout2 = nn.Dropout(p=0.45).to(d)
        self.tanh200 = Tanh200().to(d)
        self.hidden_layers = nn.ModuleList().to(d)

        # Initialize weights of Linear layers using Xavier initialization
        init.xavier_uniform_(self.fc1.weight).to(d)
        init.xavier_uniform_(self.layer2.weight).to(d)

        self.loss = nn.MSELoss().to(d)

    def forward(self, x):
        x = self.fc1(x).to(d)
        x = self.bn1(x).to(d)
        x = self.dropout1(x).to(d)
        x = self.relu(x).to(d)
        x = self.layer2(x).to(d)
        x = self.dropout2(x).to(d)
        x = self.tanh200(x).to(d)
        return x


class MemoryEstimator:
    def __init__(self, threshold_percent):
        self.threshold_percent = threshold_percent

    def estimate_memory(self):  # used for getting total RAM in percent
        return psutil.virtual_memory().available * 100 / psutil.virtual_memory().total

    def estimate_count(
        self, threshold_percent
    ):  # used for estimating how many games to analyse before reaching threshold
        before = psutil.virtual_memory().available / psutil.virtual_memory().total
        after = subprocess.run(
            ["python3", "aidata.py", str(0), str(TEST_PRECISION), "True"],
            capture_output=True,
        )  # do test run with 10 games
        after = float(str(after.stdout.decode("utf-8").strip()))
        # find memory reduction
        memory_reduction = (
            before - after
        ) / TEST_PRECISION  # memory in percent that each test game contributed
        # find the number of games based on threshold_percent
        total_samples = abs((threshold_percent / 100) / memory_reduction)
        print(total_samples)
        # try:
        #     with open("progressX.txt", "r+") as f:
        #         contents = f.read()
        #     contents = contents.split(" ")
        #     completed = int(contents[0])
        # except Exception:
        #     completed = 0
        with open("progressX.txt", "w") as f:  # overwrite file contents
            f.write(str(completed) + " " + str(int(total_samples)))
        return int(total_samples)

# import torch.nn.functional as F


class Train(Tanh200):
    def __init__(self, X_train, y_train, X_val, y_val):
        self.X_train = X_train
        self.y_train = y_train
        self.X_val = X_val
        self.y_val = y_val

    def cycle(self, X_train, y_train, X_val, y_val, best_score, l1_lambda=0.001, l2_lambda=0.001):
        model = Agent().to(d)
        X_train, y_train, X_val, y_val = X_train.to(
            d), y_train.to(d), X_val.to(d), y_val.to(d)
        # Weight initialization
        try:
            weights_path = "./zlv7_full.pt"
            state_dict = torch.load(weights_path, map_location=d)
            model.load_state_dict(state_dict)
        except FileNotFoundError:
            for m in model.modules():
                if isinstance(m, nn.Linear):
                    nn.init.xavier_uniform_(m.weight)
                    if m.bias is not None:
                        nn.init.constant_(m.bias, 0)

        # loss function and optimizer
        loss_fn = nn.MSELoss()  # mean square error
        # loss_fn2 = nn.HuberLoss()
        # loss_fn3 =
        # Set weight_decay to 0 for L2 regularization
        optimizer = optim.AdamW(
            model.parameters(), lr=1e-5, weight_decay=0.003)
        scheduler = optim.lr_scheduler.ReduceLROnPlateau(
            optimizer, factor=0.98, patience=3, verbose=True
        )
        n_epochs = 300
        batch_size = 8192  # size of each batch
        batch_start = torch.arange(0, len(X_train), batch_size)

        # Hold the best model
        best_mse = np.inf  # initialise value as infinite
        best_weights = None
        history = []
        accumulation_steps = 2  # accumulate gradients over 2 batches
        for _ in tqdm.tqdm(range(n_epochs), desc="Epochs"):
            model.train()
            epoch_loss = 0.0
            for i, batch_idx in enumerate(batch_start):
                batch_X, batch_y = (
                    X_train[batch_idx: batch_idx + batch_size],
                    y_train[batch_idx: batch_idx + batch_size],
                )
                batch_X, batch_y = batch_X.to(dtype=torch.float32), batch_y.to(dtype=torch.float32)
                optimizer.zero_grad()
                y_pred = model.forward(batch_X).to(d)
                loss = loss_fn(y_pred, batch_y.view(-1, 1)).to(d)
                # L1 regularization
                l1_reg = torch.tensor(0.).to(d)
                for name, param in model.named_parameters():
                    if 'weight' in name:
                        l1_reg += torch.norm(param, 1)
                loss += l1_lambda * l1_reg

                # L2 regularization
                l2_reg = torch.tensor(0.).to(d)
                for name, param in model.named_parameters():
                    if 'weight' in name:
                        l2_reg += torch.norm(param, 2)
                loss += l2_lambda * l2_reg

                if d == torch.device("cuda"):
                    scaler.scale(loss).backward()  # NEED GPU

                    # accumulate gradients over several batches
                    if (i + 1) % accumulation_steps == 0 or (i + 1) == len(batch_start):
                        scaler.step(optimizer)  # NEED GPU
                        scaler.update()  # NEED GPU
                model.zero_grad()
                y_pred = model(batch_X).to(d)
                loss = loss_fn(y_pred, batch_y.view(-1, 1)).to(d)
                # L1 regularization
                l1_reg = torch.tensor(0.).to(d)
                for name, param in model.named_parameters():
                    if 'weight' in name:
                        l1_reg += torch.norm(param, 1)
                loss += l1_lambda * l1_reg

                # L2 regularization
                l2_reg = torch.tensor(0.).to(d)
                for name, param in model.named_parameters():
                    if 'weight' in name:
                        l2_reg += torch.norm(param, 2)
                loss += l2_lambda * l2_reg

                loss.backward()
                optimizer.step()
                epoch_loss += loss.item() * batch_X.shape[0]
            epoch_loss /= len(X_train)
            scheduler.step(epoch_loss)
            history.append(epoch_loss)
            if epoch_loss < best_mse:
                best_mse = epoch_loss

        print("MSE: %.2f" % best_mse)
        print("RMSE: %.2f" % np.sqrt(best_mse))
        plt.plot(history)
        plt.title("Epoch loss for ZL")
        plt.xlabel("Number of Epochs")
        plt.ylabel("Epoch Loss")
        plt.draw()
        plt.savefig("ai-eval-losses.jpg")
        best_weights = copy.deepcopy(model.state_dict())
        torch.save(best_weights, "zlv7_full.pt")
        if best_score > epoch_loss:
            best_weights = copy.deepcopy(model.state_dict())
            torch.save(best_weights, "zlv7_full.pt")
        if d == torch.device("cuda"):
            torch.cuda.empty_cache()
        del X_train
        del X_val
        del y_train
        del y_val
        gc.enable()
        gc.collect()
        gc.disable()
        return epoch_loss


def manager(size, completed):
    subprocess.run(
        ["python3", "aidata.py", str(completed), str(size), "False"], shell=False
    )


if __name__ == "__main__":
    # Define genetic algorithm parameters
    # Training loop
    completed = 0
    counter = 1
    all_completed = False
    try:
        with open("progressX.txt", "r") as f:
            contents = f.read()
    except FileNotFoundError:
        m = MemoryEstimator(RAM_USAGE)
        size = m.estimate_count(
            RAM_USAGE
        )  # memory based allocation with arg as percentage usage of RAM per cycle
    # puzzle presets
    board = chess.Board()
    completed = 0
    # find number of lines in a database

    DB_LOCATION = "./all_data.db"

    # Connect to the database
    conn = sqlite3.connect(DB_LOCATION)

    # Create a cursor object
    cursor = conn.cursor()

    # # Execute the query to get the length of the table
    cursor.execute("SELECT COUNT(*) FROM games")

    # # Fetch the result
    result = cursor.fetchone()[0]
    # print(result)
    conn.close()
    # instantiate population
    count = 0  # used for indexing which agent it is to train now
    best_score = np.inf
    while all_completed == False:
        files = ["X_train", "y_train", "X_val", "y_val"]
        for file in files:
            with open(file, "w+") as f:  # clear each file
                f.write("")
        with open("progressX.txt", "r+") as f:
            contents = f.read()
        contents = contents.split(" ")
        completed, size = int(contents[0]), int(contents[1])
        if completed != 0:
            m = MemoryEstimator(RAM_USAGE)
            estimate = m.estimate_count(RAM_USAGE)
            size = estimate
        not_done = result - completed
        if not_done == 0:
            all_completed = True
            break
        if (
            not_done < size
        ):  # size is the number of chess games processed/cycle in total
            size = not_done  # this is for the final cycle if there are any remainders
            all_completed = True
        # repeat the training process for all agents in population
        # load weights onto AI
        manager(size, completed)
        ###############################################################################################
        data = []
        for file in files:
            storagefile = open(file, "rb")
            data.append(pickle.load(storagefile))
        X_train, y_train, X_val, y_val = (
            data[0],
            data[1],
            data[2],
            data[3],
        )
        gc.enable()
        gc.collect()
        gc.disable()
        ###############################################################################################
        # print("ready")
        t = Train(X_train, y_train, X_val, y_val)
        score = t.cycle(X_train, y_train, X_val, y_val, best_score, 0.01, 0.01)
        best_score = min(best_score, score)
        completed = completed + size
        with open("progressX.txt", "w") as f:  # overwrite file contents
            f.write(str(completed) + " " + str(size))
        completed = counter * size
        del t
        del X_train
        del y_train
        del X_val
        del y_val
        gc.enable()
        gc.collect()
        gc.disable()
        counter += 1
